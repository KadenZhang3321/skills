# Shanghai Cluster (openmerlin-shanghai-001) 部署手册与问题记录

## 集群架构

| 层级 | 节点 | 位置 | 架构 | 规格 |
|------|------|------|------|------|
| 云上 | master-01/02/03 | 华为云 ECS | x86_64 | 4C8G, Ubuntu 22.04 |
| 云下 | lab-worker-01/02/03/04 | 实验室 | aarch64 | 384C/1.5TB, 8× Ascend950DT, openEuler 24.03 |
| 服务 | admin123 (192.168.13.107) | 实验室 | x86_64 | 56C/251G, Ubuntu 22.04 |

**网络**：

| 网段 | 接口 | 用途 |
|------|------|------|
| 10.254.1.0/24 | eth1（master）/ enp34s0f1（lab） | 管理面 — kube-apiserver、etcd |
| 10.254.9.0/24 | eth0（master） | 服务面 — Cilium pod 网络 |
| 192.168.8.0/21 | enp34s0f1（lab） | 云下面管理 |
| 178.27.0.0/18 | data0（lab） | 云下面数据、NFS |

**ELB**：

| ELB | 地址 | 用途 |
|-----|------|------|
| 管理面 | `115.175.0.82:6443`（内 `10.254.1.33`） | 对外 API server（白名单） |
| 服务面 | `10.254.9.147:6443` | Pod 内部访问 |

---

## 第一步：K8s 集群初始化

### 1.1 master 节点系统准备

```bash
# 所有 master 执行
hostnamectl set-hostname master-0X
swapoff -a && sed -i '/swap/d' /etc/fstab
modprobe overlay && modprobe br_netfilter
sysctl -w net.bridge.bridge-nf-call-iptables=1 net.ipv4.ip_forward=1
```

### 1.2 安装 containerd（master）

containerd v2.2.6，配置 SystemdCgroup + 阿里云镜像加速：

```bash
apt-get install -y containerd.io
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i "s|sandbox_image = 'registry.k8s.io/pause:.*'|sandbox_image = 'registry.aliyuncs.com/google_containers/pause:3.10'|" /etc/containerd/config.toml
```

**问题**: Master 节点可直连外网，但 `registry.k8s.io` 偶尔慢。

**解决**: 配置 containerd certs.d mirror 到阿里云。

---

### 1.3 kubeadm init

```bash
kubeadm init \
  --apiserver-advertise-address=10.254.1.187 \
  --control-plane-endpoint=10.254.1.187:6443 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --image-repository=registry.aliyuncs.com/google_containers
```

> **问题**: 证书只包含 `10.254.1.187`，后续添加的 ELB IP 不在 SAN 中会导致 TLS 验证失败。

> **解决**: 后续补全 certSANs 并重新生成证书（见 3.2）。

---

## 第二步：Cilium CNI 安装

```bash
cilium install \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
  --set devices=eth0,enp34s0f1 \
  --set kubeProxyReplacement=true
```

### 2.1 Cilium cluster-pool CIDR 与 kubeadm CIDR 不一致

**现象**: Pod 实际 IP 为 `10.0.x.x`，而非 kubeadm 设置的 `10.244.0.0/16`。

**根因**: Cilium 默认 `cluster-pool-ipv4-cidr: 10.0.0.0/8`，忽略 kubeadm 的 `--pod-network-cidr`。

**解决**: `ipv4-native-routing-cidr` 后续改为 `10.0.0.0/8` 与实际 Pod IP 对齐。

### 2.2 Flannel CNI 残留冲突

**现象**: CoreDNS pod 报 `plugin type="flannel" failed`，实际是旧 flannel 配置未清理。

**解决**: `rm -rf /etc/cni/net.d/*` + 重启 kubelet。

---

## 第三步：证书与 ELB 配置

### 3.1 加入 master-02/03

```bash
kubeadm join 10.254.1.187:6443 --token ... --control-plane ...
```

### 3.2 证书加 ELB SAN

**需求**: 管理面 ELB `115.175.0.82`，服务面 ELB `10.254.9.147`，以及所有节点的管理和服务 IP。

**步骤**:

```bash
# 1. 更新 kubeadm-config
kubectl edit cm -n kube-system kubeadm-config
# 添加 certSANs:
#   - 10.254.1.187, 10.254.1.232, 10.254.1.25     (管理)
#   - 10.254.9.49, 10.254.9.229, 10.254.9.85      (服务)
#   - 10.254.9.147                                   (服务面 ELB)
#   - 115.175.0.82                                   (管理面 ELB)

# 2. 每台 master 重新生成证书
rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
kubeadm init phase certs apiserver --config <(kubectl get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}')

# 3. 重启 API server（在各 master 上）
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 2
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

### 3.3 证书重新生成时丢失老 SAN 致 API server 全部 CrashLoop

**现象**: 只添加 `10.254.9.147` 和 `115.175.0.82` 到 certSANs，但实际 API server 监听 `10.254.1.187`，该 IP 不在新证书中。kubelet 无法连 API server，导致 API server 自身也无法启动（静态 pod）。

**根因**: kubeadm init phase certs 不自动合并已有 SAN，只会按 ConfigMap 重新生成。

**解决**: 每次生成证书前确保 `certSANs` 列表包含**所有** 需要访问 API server 的 IP。生成后必须分发到所有 master 并重启 API server。

### 3.4 更新 cluster-info ConfigMap

kubeadm join 时 lab 节点从 `kube-public/cluster-info` ConfigMap 读取 server 地址。需更新为 ELB：

```bash
kubectl edit cm -n kube-public cluster-info
# 改 server 为 https://10.254.9.147:6443
```

### 3.5 更新 kube-proxy ConfigMap

kube-proxy 的内部 kubeconfig 也指向老地址，需同步更新：

```bash
kubectl edit cm -n kube-system kube-proxy
# 改 server 为 https://10.254.9.147:6443
```

---

## 第四步：lab 节点加入集群

### 4.1 系统准备（OpenEuler aarch64）

```bash
hostnamectl set-hostname lab-worker-0X
swapoff -a && sed -i '/swap/d' /etc/fstab
# OpenEuler 无 systemd-resolved:
mkdir -p /run/systemd/resolve
ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf
```

> **问题**: swap 未关 → kubelet 启动失败。
> **问题**: `/run/systemd/resolve/resolv.conf` 不存在 → Pod sandbox 创建失败。
> **解决**: 以上两行。

### 4.2 安装 containerd（OpenEuler v1.6）

OpenEuler 自带 containerd v1.6，使用**旧版** config 格式：

```toml
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
  endpoint = ["https://docker.m.daocloud.io"]
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
  endpoint = ["https://registry.aliyuncs.com/google_containers"]
```

> **问题**: containerd v1.6 不支持 `certs.d` 目录格式。`sandbox_image` 格式为 `sandbox_image = "..."`（双引号），不同于 v2.x 的单引号格式。

### 4.3 安装 kubeadm/kubelet（lab 节点无外网）

lab 节点的 DNS 解析不稳定，`pkgs.k8s.io` 可能不通。

**解决**: 从 master-01 下载 aarch64 RPM 包 → scp → 本地 rpm 安装：

```bash
# master-01
curl -LO https://pkgs.k8s.io/core:/stable:/v1.32/rpm/aarch64/kubeadm-1.32.13-150500.1.1.aarch64.rpm
# ... kubectl, kubelet, cri-tools
scp *.rpm root@192.168.13.244:/tmp/

# lab 节点
rpm -ivh --nodeps /tmp/*.rpm   # --nodeps 跳过 kubernetes-cni 依赖
echo 'KUBELET_EXTRA_ARGS=--node-ip=192.168.13.24X' > /etc/default/kubelet
```

### 4.4 kubeadm join

```bash
kubeadm join 10.254.9.147:6443 \
  --token ... \
  --discovery-token-ca-cert-hash sha256:... \
  --cri-socket unix:///var/run/containerd/containerd.sock
```

> **问题**: 两节点 hostname 都是 `localhost.localdomain`，K8s 认作同一个节点，后者覆盖前者。

> **解决**: 提前 `hostnamectl set-hostname` 设为唯一名。

---

## 第五步：Pod 网络与 DNS 修复

这是整个部署最耗时的一步，共涉及 7 个子问题。

### 5.1 DNS 链路的三个断裂点

```
Pod (10.0.x.x)
  → CoreDNS ClusterIP (10.96.0.10)     [断裂点1]
  → CoreDNS pod → forward → 上游DNS     [断裂点2]
  → 上游DNS回复 → 回不到 Pod             [断裂点3]
```

### 5.2 断裂点1：Cilium service 路由不工作

**现象**: Pod 内 `curl https://10.96.0.1:443` 超时。CoreDNS kubernetes 插件 `Still waiting on: kubernetes`。

**根因**: `kube-proxy-replacement: "true"` 时 Cilium 用 BPF 处理 Service IP 路由，但未正确工作。

**解决**: 关闭 kube-proxy replacement，让 iptables 接管：
```bash
kubectl edit cm -n kube-system cilium-config
# kube-proxy-replacement: "false"
kubectl delete pod -n kube-system -l k8s-app=cilium
```

验证：`kubectl exec <pod> -- python3 -c "import urllib.request; urllib.request.urlopen('https://10.96.0.1:443/healthz')"` 返回 `ok`。

### 5.3 断裂点2：CoreDNS 转发到不可达 DNS

**现象**: Pod DNS 查询到 CoreDNS 后，CoreDNS 转发超时，返回 SERVFAIL。

**根因**: 初期 CoreDNS `forward . /etc/resolv.conf` 拿到节点 DNS `114.114.114.114`，但 lab 节点实际上无法访问 114.114.114.114（ICMP 被过滤但公网不一定通）。后续改用 `178.27.1.100`（数据面 DNS），可从 node 访问。

**解决**: 逐步修正 CoreDNS forward 目标：
```
114.114.114.114 8.8.8.8              → 不通
178.27.1.100 114.114.114.114         → 178.27.1.100 可达但回包路由不通（5.4）
/etc/resolv.conf                      → 恢复默认，等 Pod 网络修好后自然通
```

最终：CoreDNS 用 `/etc/resolv.conf`，lab 节点 DNS 顺序调整为 114 在前（优先）。

### 5.4 断裂点3：回包路由不通（Cilium masquerade 未覆盖）

**现象**: CoreDNS 能发 UDP 到 `178.27.1.100:53`，host 上 `nslookup api.github.com 10.0.4.x` 成功，但 Pod 内同样的查询超时。

**根因**: 数据面网络（178.27.0.0/18）没有 Pod 网段（10.0.0.0/8）的路由。CoreDNS pod 使用其 Pod IP (10.0.x.x) 发送 DNS 请求时，回包在 178.27.0.0/18 段找不到回程。Cilium 的 iptables masquerade 规则有 `oifname != "cilium_*"` 条件，放过 `cilium_host` 出口的流量，导致未做 SNAT。

**解决**: 开 BPF masquerade + NodePort：
```bash
kubectl edit cm -n kube-system cilium-config
# enable-bpf-masquerade: "true"
# enable-node-port: "true"           ← BPF masquerade 的依赖
```

> **注意**: 必须同时开 `enable-node-port`，否则 Cilium agent CrashLoop（报 `BPF masquerade requires NodePort`）。

### 5.5 Pod DNS 临时绕过方案

在 DNS 完全修复之前，给关键 Pod（ARC controller、listener、runner）加 `dnsPolicy: None` + 直接 DNS：

```yaml
dnsPolicy: "None"
dnsConfig:
  nameservers: ["114.114.114.114"]
```

**注意**: 这只是过渡方案，DNS 修复后应去掉。最终 PR 中的 values.yaml 不需要。

### 5.6 Cilium agent 反复 CrashLoop

**现象**: 改完 ConfigMap 重启 Cilium 后 agent CrashLoop。

**根因**: 多次修改 ConfigMap 使用 `kubectl replace --force`（先删后建），但 Cilium agent 启动时需要完整配置。ConfigMap 短暂不存在时 agent 无法启动。

**解决**: 使用 `kubectl edit` 或 `kubectl apply` 而非 `replace --force`。

### 5.7 CoreDNS pod 卡在 0/1

**现象**: CoreDNS pod `0/1 Running`，readiness 503。

**根因**: CoreDNS kubernetes 插件启动时需要连接 API server，但 Cilium 未就绪时 Service IP 不通，插件进入等待循环。

**解决**: Cilium 全部 Ready 后重启 CoreDNS pod。

---

## 第六步：lab 节点时钟同步

### 6.1 时钟快 8 小时导致 Runner 无限循环

**现象**:
- Runner pod 日志 `The token is not valid until 07/16/2026 21:43:24. Current server time is 07/16/2026 13:43:09`
- Runner 启动 → 注册 JIT → session 创建失败 → 退出 → listener 重新创建 → 无限循环
- GitHub job 永远 QUEUED

**根因**: lab 节点系统时钟快 8 小时（`Fri Jul 17 05:43 CST` vs 实际 `Fri Jul 16 21:43 CST`）。GitHub JIT token 的 `nbf` claim 基于实际的 UTC 时间签发，但 runner 用本地错误时间校验，token 看起来还未生效。

**解决**:
```bash
date -s @$(ssh master-01 date +%s)
```

**后续**: 需配置 NTP 永久修复（`chronyd` 或 `ntpdate` + cron）。

---

## 第七步：镜像拉取

### 7.1 registry.k8s.io 不可达

**解决**: 所有节点 containerd 配置 aliyuncs mirror：
```
registry.k8s.io → registry.aliyuncs.com/google_containers
```

### 7.2 quay.io 不可达

**现象**: Cilium 镜像 `quay.io/cilium/*` 拉取超时。quay S3 CDN TLS 握手失败。

**解决**:
- Docker Hub 镜像走 `docker.m.daocloud.io`
- quay.io 镜像从已部署节点 `ctr images export/import`
- 或配置 containerd mirror `quay.m.daocloud.io`

### 7.3 daocloud 401

**现象**: `curl https://docker.m.daocloud.io/v2/` 返回 401。

**根因**: Docker Registry API 的标准行为——`/v2/` 返回 401 要求认证，但 containerd 会自动完成 token 交换。**不是真正的认证失败**。

---

## 第八步：GitHub Actions Runner

### 8.1 ARC Controller 安装

```bash
helm install arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace arc-systems --version 0.14.2 \
  --set image.repository=swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/gha-runner-scale-set-controller \
  --set image.tag=0.14.201
```

> **问题**: Helm chart OCI 仓库 `ghcr.io` 在国内慢。

> **解决**: 本地 `helm pull` + `helm dependency update` → tar → scp 到 master。

### 8.2 Runner Scale Set 安装

```bash
helm install linux-aarch64-950dt-8 oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace vllm-project --version 0.14.2 \
  -f values.yaml
```

### 8.3 Runner 无限循环创建

见第六步——时钟问题导致。

### 8.4 Listener hostNetwork 端口冲突

**现象**: Listener pod Pending，`0/5 nodes are available: 3 node(s) didn't have free ports for the requested pod ports`

**根因**: Helm 模板默认加 hostPort 8080（metrics），搭配 hostNetwork 时单节点只能跑一个。

**解决**: 网络修复后去掉 hostNetwork 和 dnsPolicy override，listener 用独立网络栈。

### 8.5 反复重装导致 scale set ID 变化

**现象**: 多次 `helm uninstall` + `helm install` 后，GitHub job 永远 QUEUED。

**根因**: 每次重装向 GitHub 注册新 scale set ID，旧 job 已绑定到旧 ID。

**解决**: 安装一次后不再动。生产环境依赖 ArgoCD GitOps，不存在重复卸载问题。

### 8.6 maxRunners=0 锁死

**现象**: EphemeralRunnerSet replicas=0，listener 不创建 runner。

**根因**: 手动 `kubectl patch` 设了 maxRunners=0 用于停止循环，但 Helm values 不带这个字段，`helm upgrade` 无法恢复。

**解决**: `kubectl patch autoscalingrunnerset <name> -p '{"spec":{"maxRunners":10}}'`

---

## 第九步：Ascend NPU 运行时

### 9.1 Ascend Docker Runtime 安装

```bash
# lab 节点
./Ascend-docker-runtime_7.0.RC1_linux-aarch64.run --install --install-scene=containerd
```

### 9.2 Runtime 版本不匹配

**现象**: 容器 `ascend-docker-runtime did not terminate successfully: exit status 1`，日志 `dcmi init failed, error code: -8255`

**根因**: v7.0.RC1 只支持 DCMIv1，而 Device Plugin v26.x 用 DCMIv2。Ascend950DT 需要 v26.x Runtime。

**解决**: 升级到 v26.1.0.beta.2。**踩坑**: installer 文件名必须包含 `aarch64` 字符串。

### 9.3 containerd 配置 ascend runtime

Containerd v1.6（OpenEuler）需在 `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]` 段加：

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.ascend]
  runtime_type = "io.containerd.runtime.v1.linux"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.ascend.options]
    BinaryName = "/usr/local/Ascend/Ascend-Docker-Runtime/ascend-docker-runtime"
```

同时需要 v1 compat 段供 device plugin 检测：
```toml
[plugins."io.containerd.runtime.v1.linux"]
  runtime = "/usr/local/Ascend/Ascend-Docker-Runtime/ascend-docker-runtime"
```

---

## 第十步：Ascend 设备管理

### 10.1 Device Plugin

```yaml
args:
  - "-useAscendDocker=true"
  - "-volcanoType=true"
  - "-autoStowing=true"
  - "-presetVirtualDevice=true"    # 950DT 只支持静态虚拟化
```

> **问题**: 设 `presetVirtualDevice=false` 后 CrashLoop，报 `only 310p, 910a2 and 910a3 support presetVirtualDevice false`。
> **解决**: 保持 `true`。

### 10.2 Resource name 不匹配

**现象**: Volcano `Unschedulable: huawei.com/ascend-a5 not found`

**根因**: ConfigMap 写 `huawei.com/ascend-a5`，device plugin 注册的是 `huawei.com/npu`

**解决**: 全部 ConfigMap 改为 `huawei.com/npu`

### 10.3 workflow pod liburma.so.0 缺失

**现象**: 容器 Started 后 300s FailedPostStartHook，日志 `liburma.so.0: cannot open shared object file`

**根因**: Ascend950DT npu-smi 依赖 `umdk-urma-lib` 中的 `liburma.so.0`，安装在 `/usr/lib64`，workflow pod 未挂载。

**解决**: ConfigMap 加 hostPath `/usr/lib64` → 容器 `/usr/lib64`

---

## 第十一步：Volcano 调度器

### 11.1 安装

镜像从 `docker.m.daocloud.io/volcanosh/` 拉取（ARM64），共 4 个：`vc-controller-manager`, `vc-scheduler`, `vc-webhook-manager`, `vc-agent`

### 11.2 NPU 插件

**问题**: `validNPUJob failed: no policy handler registered`

**根因**: 950DT 没有默认调度策略 handler。

**解决**: ConfigMap PodTemplate 加 annotation `huawei.com/schedule_policy: chip1-node8`

### 11.3 Volcano 部署到 master 节点（资源限制）

**问题**: master 只有 4C8G，Volcano 默认请求较大。

**解决**: 下调资源请求到适配 4C8G；用 buildah 构建 amd64 镜像供 master 使用。

---

## 第十二步：CI 配置管理

### 12.1 values.yaml 与 A3 对齐

**要求**: PR 中 values.yaml 必须与已有 A3 runner 配置完全对齐，仅改标签。

**最终方案**:
```bash
cp linux-aarch64-a3-8/values.yaml linux-aarch64-950dt-8-shanghai/values.yaml
sed -i 's/a3-8/950dt-8/g; s/ascend-1980/ascend-950dt/g; s/gy-005/shanghai-001/g'
```

### 12.2 yamllint

PR 的 yamllint 检查报 `too few spaces after comma`。

**解决**: 从 A3 直接复制保证格式完全一致。

---

## 第十三步：Service 管理

### 13.1 resource-api + vue-frontend

在 master 节点部署，arc-system namespace。

### 13.2 Admin123 服务节点搭建

新增 x86 节点 `192.168.13.107`，从 master 迁移以下服务：
- resource-api、ARC controller、listeners
- secrets-manager、imagepullsecret-patcher
- nginx-pypi-cache（PyPI/APT/Rust/YUM 缓存）

**配置要点**:
- DNS 顺序：114 在前优先，178.27.1.100 在后
- containerd mirror: daocloud + aliyuncs
- 无 storage provisioner：PVC 改 hostPath

### 13.3 Weight NFS 新节点不可见

**问题**: lab-03/04 没有 `/mnt/weight` NFS 挂载。

**解决**: 改 weight 路径为 `/mnt/share/vllm-ascend/weight`（共享 NFS 所有节点都有），`type: DirectoryOrCreate`

---

## 待完成

| # | 事项 | 优先级 |
|---|------|:--:|
| 1 | ArgoCD 注册集群 + PR 合入 | 高 |
| 2 | lab 节点 NTP 永久配置 | 中 |
| 3 | CoreDNS 转发回包路由彻底修复 | 中 |
| 4 | Volcano + Device Plugin + NodeD 部署完成 | 中 |
| 5 | Listener/runner dnsPolicy workaround 去掉 | 低 |
