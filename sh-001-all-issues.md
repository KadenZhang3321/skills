# Shanghai Cluster (openmerlin-shanghai-001) 全流程问题与解决

## 集群架构

| 层级 | 节点 | 位置 | 架构 | 规格 |
|------|------|------|------|------|
| 云上（控制面） | master-01/02/03 | 华为云 ECS | x86_64 | 4C8G, Ubuntu 22.04 |
| 云下（计算面） | lab-worker-01/02/03/04 | 实验室物理机 | aarch64 | 384C/1.5TB, 8× Ascend950DT, openEuler 24.03 |
| 服务节点 | admin123 (192.168.13.107) | 实验室 | x86_64 | 56C/251G, Ubuntu 22.04 |

**网络**：管理面 10.254.1.x（云上eth1）+ 192.168.8.0/21（云下enp34s0f1），服务面 10.254.9.x（云上eth0），数据面 178.27.0.0/18（云下data0）。ELB 115.175.0.82:6443（管理面），10.254.9.147:6443（服务面）。

---

## 一、基础设施与网络

### 1.1 Pod DNS 完全不通

**现象**：任何 Pod 内 `nslookup api.github.com` 超时，`Temporary failure in name resolution`。ARC controller 日志 `lookup api.github.com: i/o timeout`，listener 无法注册到 GitHub。

**根因**：三条链路依次断裂：

1. **CoreDNS 转发到不可达 DNS**：lab 节点 `/etc/resolv.conf` 配置 `nameserver 114.114.114.114`，但 `114.114.114.114` 从 lab 网络实际无法访问（ICMP 被过滤）。CoreDNS 的 `forward . /etc/resolv.conf` 拿到的是节点 DNS 列表，转发超时。

2. **CoreDNS kubernetes 插件初始化失败**：CoreDNS 启动时需要连接 `10.96.0.1:443` 列 watch K8s API，但 Cilium `kube-proxy-replacement=true` 时 Pod 到 Service IP 的路由不工作，导致插件一直 `Still waiting on: kubernetes`，CoreDNS 不响应任何查询。

3. **Cilium masquerade 不生效**：即使 CoreDNS 能转发 DNS 请求到上游（178.27.1.100 可达），回包也无法路由回 Pod 网段（10.0.0.0/8）。数据面网络（178.27.0.0/18）没有 Pod 网段的路由。Cilium iptables masquerade 规则中 `oifname != "cilium_*"` 条件导致通过 `cilium_host` 出口的流量被跳过 SNAT。

```
Pod (10.0.x.x) → CoreDNS → 178.27.1.100
178.27.1.100 的回复 → ??? → 回不到 10.0.x.x
```

**解决**：

| 步骤 | 操作 |
|------|------|
| 1 | CoreDNS forward 改为 `178.27.1.100 114.114.114.114`（可达 DNS 排前） |
| 2 | Cilium 启用 `enable-bpf-masquerade: true` + `enable-node-port: true`，用 BPF 代替 iptables 做 SNAT |
| 3 | `ipv4-native-routing-cidr` 从错误的 `10.244.0.0/16` 修正为 `10.0.0.0/8`（与实际 Pod IP 段对齐） |
| 4 | `kube-proxy-replacement` 从 `true` 改为 `false`，让 kube-proxy iptables 接管 Service IP 路由 |
| 5 | listener/runner Pod 临时加 `dnsPolicy: None` + `dnsConfig.nameservers: [114.114.114.114]` 绕过 CoreDNS |
| 6 | ARS Controller deployment 也加 `dnsPolicy: None`，确保其能解析 `api.github.com` |
| 7 | CoreDNS ConfigMap 最终恢复到 `forward . /etc/resolv.conf`（因节点 DNS 已修复） |

---

### 1.2 K8s Service IP (10.96.0.1) 从 Pod 不通

**现象**：CoreDNS 的 kubernetes 插件报 `dial tcp 10.96.0.1:443: i/o timeout`，listener 报 `fetch EphemeralRunnerSet: i/o timeout`。

**根因**：与 1.1 同源——Cilium kube-proxy replacement 不工作。

**解决**：同 1.1 步骤 4。验证：`kubectl exec ... -- python3 -c "urllib.request.urlopen('https://10.96.0.1:443/healthz')"` 返回 `ok`。

---

### 1.3 Cilium agent CrashLoop（BPF masquerade 依赖 NodePort）

**现象**：`kubectl logs cilium-xxx` 显示 `BPF masquerade requires NodePort (--enable-node-port="true")`

**根因**：单独启用 BPF masquerade 而没启用 NodePort 时，Cilium agent 启动即崩溃。

**解决**：Cilium ConfigMap 同时设置 `enable-bpf-masquerade: "true"` 和 `enable-node-port: "true"`。

---

### 1.4 Lab 节点时钟偏差 8 小时

**现象**：Runner pod 日志 `The token is not valid until 07/16/2026 21:43:24. Current server time is 07/16/2026 13:43:09.`

**根因**：lab 节点（openEuler 24.03）系统时钟比实际时间快 8 小时（`Fri Jul 17 05:43 AM CST` vs 实际 `Fri Jul 16 21:43 CST`）。GitHub JIT token 的 `nbf` 基于 listener 注册时的服务器时间签发，runner 使用它时，token 看起来还不应该生效（"issued in the future"），导致 `Failed to create a session` → runner 退出 → listener 创建新 runner → 无限循环。

**解决**：`date -s @<master-epoch>` 同步到 master 时间。需配置 NTP 永久修复。

---

### 1.5 containerd sandbox 镜像不可达

**现象**：lab 节点上所有 Pod 的 sandbox 创建失败，kubelet 日志 `Failed to create sandbox: failed to pull image "registry.k8s.io/pause:3.10.1"`

**根因**：lab 节点无外网直连，`registry.k8s.io` 不可达。

**解决**：containerd config 中 `sandbox_image` 改为 `registry.aliyuncs.com/google_containers/pause:3.10`。containerd v1.6（OpenEuler 自带）用旧版 config 格式（`[plugins."io.containerd.grpc.v1.cri".registry.mirrors]`），与 v2.x 的 `certs.d` 不兼容。

---

### 1.6 拉取 quay.io 镜像超时

**现象**：Cilium pod `ImagePullBackOff`，describe 显示 `quay.io/cilium/*` 拉取超时。

**根因**：quay.io 的 S3 CDN（`cdn01.quay.io`）TLS 握手超时。`docker.m.daocloud.io` 可以代理 Docker Hub 但不代理 quay.io。

**解决**：通过 `m.daocloud.io` 拉取 Docker Hub 镜像；Cilium 等 quay.io 镜像从已有节点 `ctr images export/import` 或通过 containerd mirror 配置 `quay.m.daocloud.io` 代理。

---

### 1.7 DNS 回包路由问题（Cilium hostNetwork pod）

**现象**：hostNetwork pod 的 DNS 指向 CoreDNS ClusterIP `10.96.0.10`，跨节点 pod 路由不通时 DNS 全挂，listener 反复 `count=5, rejecting all runners`。

**根因**：Cilium cluster health 只有 1/7（大部分节点间 pod 路由断裂）。

**解决**：修复底层路由后 Cilium health 恢复到 7/7，DNS 通。

---

### 1.8 CoreDNS pod 卡在 0/1 Ready

**现象**：CoreDNS pod 显示 `0/1 Running`，readiness probe 503。

**根因**：CoreDNS kubernetes 插件在 API server 不可达时进入等待循环，直到超时后才开始服务。Cilium 未就绪时 API server service IP 不通。

**解决**：等 Cilium 就绪后重启 CoreDNS pod。

---

## 二、K8s 集群搭建

### 2.1 kubeadm init 证书不含 ELB SAN

**现象**：`kubeadm join 10.254.9.147:6443` 报 `x509: certificate is valid for 10.96.0.1, 10.254.1.187, not 10.254.9.147`

**根因**：`kubeadm init` 时 control-plane-endpoint 设为 `10.254.1.187:6443`，证书只包含该 IP。ELB IP `10.254.9.147` 不在证书 SAN 中。

**解决**：更新 kubeadm-config ConfigMap 添加所有需要的 IP 到 `apiServer.certSANs`，`kubeadm init phase certs apiserver --config` 重新生成证书，分发到所有 master。

**最终 certSANs 列表**：`10.254.1.187, 10.254.1.232, 10.254.1.25, 10.254.9.49, 10.254.9.229, 10.254.9.85, 10.254.9.147, 115.175.0.82`

### 2.2 证书重新生成时删除老 SAN 导致 API server CrashLoop

**现象**：运行 `kubeadm init phase certs apiserver` 后 API server 全部 CrashLoopBackOff。kubectl 报 `certificate is valid for ..., not 10.254.1.187`

**根因**：只把新增的 SAN 写入 ConfigMap 但没保留老的 SAN。证书重新生成后不包含 API server 实际监听的 `10.254.1.187`，导致 TLS 握手失败。

**解决**：在 ConfigMap 中补齐所有节点的管理和服务 IP，重新生成证书并分发到三台 master。

---

### 2.3 kubeadm join 时 fetch cluster-info 失败

**现象**：lab 节点 `kubeadm join 10.254.9.147:6443` 报 `failed to request the cluster-info ConfigMap: context deadline exceeded`，后报证书不匹配。

**根因**：两步失败——先用 `115.175.0.82` 不通（lab 节点不在白名单），后用 `10.254.9.147` 通但证书不含该 IP。

**解决**：加证书 SAN + 更新 cluster-info ConfigMap 中的 server 地址 + 用正确的 ELB IP。

---

### 2.4 lab 节点 OpenEuler 无 systemd-resolved

**现象**：Pod sandbox 创建失败 `open /run/systemd/resolve/resolv.conf: no such file or directory`

**根因**：OpenEuler 不使用 systemd-resolved，`/run/systemd/resolve/` 目录不存在。

**解决**：`mkdir -p /run/systemd/resolve && ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf`

---

### 2.5 lab 节点 swap 未关闭

**现象**：kubelet 启动失败 `failed to run Kubelet: running with swap on is not supported`

**根因**：lab 节点初始状态 swap 未关。

**解决**：`swapoff -a && sed -i '/swap/d' /etc/fstab`

---

## 三、GitHub Actions Runner

### 3.1 反复重装导致 scale set ID 变化，job 永远 queued

**现象**：多次 `helm uninstall` + `helm install` 后 GitHub 上的 job 状态一直 `QUEUED`/`waiting`，不分配 runner。

**根因**：每次重装 Helm 都会创建新的 AutoscalingRunnerSet，向 GitHub 注册一个新的 scale set ID。之前 PR 触发的 job 已被绑定到旧 scale set ID，新 scale set 看不到。GitHub 不会自动将 job 迁移到新 scale set。

**解决**：稳定安装一次，不再卸载。需要测试时用新建 PR 触发新的 job（绑定到当前 scale set）。生产环境依赖 ArgoCD GitOps 管理，不存在重复卸载的问题。

---

### 3.2 Runner 不停循环创建

**现象**：listener 日志显示 `count=1`，创建 runner pod，runner 立即失败退出，listener 创建下一个 runner……反复循环。

**根因**：时钟偏差导致 JIT token nbf 校验失败（见 1.4）。runner 每次启动 → 注册 → 创建 session 失败 → 退出 → listener 检测到 runner 消失 → 再创建。

**解决**：修复时钟后循环自停。

---

### 3.3 Listener hostNetwork 端口冲突

**现象**：listener pod Pending，`0/5 nodes are available: 3 node(s) didn't have free ports for the requested pod ports`

**根因**：listener 模板使用 hostNetwork + hostPort 8080（metrics），单节点只能跑一个 listener。当 3 个 listener 调度到同一节点时冲突。

**解决**：去掉 hostNetwork 和 dnsPolicy override（网络已修复），listener 用独立 pod 网络栈，无端口冲突。

---

### 3.4 a5-8 maxRunners=0 锁死

**现象**：a5-8 EphemeralRunnerSet replicas=0，listener 永远不创建 runner

**根因**：手动 `kubectl patch` 设了 maxRunners=0 用于停止循环，但 Helm values 不带这个字段，`helm upgrade` 无法恢复。

**解决**：`kubectl patch autoscalingrunnerset linux-aarch64-a5-8 -p '{"spec":{"maxRunners":10}}'`

---

### 3.5 Runner 模板架构不匹配（已确认无实际影响）

**现象**：Runner pod 怀疑因 AMD64 镜像调度到 ARM64 节点失败。

**根因**：runner 镜像（`swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/runner-containers-hooks:release-no_volumes-9c3ea5`）实际上支持多架构（`linux/amd64,linux/arm64`），不是根因。

**解决**：PR values.yaml 最终与 A3 对齐——runner 模板不设 nodeSelector，默认跑在任意可用节点上。

---

## 四、Ascend NPU

### 4.1 Ascend Docker Runtime v7.0.RC1 vs v26.1.0.beta.2

**现象**：容器 `ascend-docker-runtime did not terminate successfully: exit status 1`，日志 `dcmi init failed, error code: -8255`

**根因**：Runtime v7.0.RC1 只支持 DCMIv1 API，而 Device Plugin v26.1.0.beta.2 用 DCMIv2 API。Ascend950DT 需要 v26.x Runtime。

**解决**：升级 Runtime 到 v26.1.0.beta.2。注意：installer 文件名必须包含 `aarch64` 字符串。

---

### 4.2 Device Plugin presetVirtualDevice 参数

**现象**：设为 `presetVirtualDevice=false` 后 device plugin CrashLoop，错误 `only 310p, 910a2 and 910a3 support presetVirtualDevice false`

**根因**：Ascend950DT 只支持静态虚拟化。

**解决**：保持 `presetVirtualDevice=true`，配置 vnpu.cfg `dev0:0-7`（1×8 卡虚拟设备）。

---

### 4.3 Volcano NPU 插件缺失

**现象**：`validNPUJob failed: no policy handler registered`

**根因**：Volcano NPU 插件需要 pod annotation `huawei.com/schedule_policy` 指定调度策略。950DT 没有默认 handler。

**解决**：ConfigMap 的 PodTemplate 加 annotation `huawei.com/schedule_policy: chip1-node8`

---

### 4.4 workflow pod liburma.so.0 缺失

**现象**：容器 Started 后 300 秒 FailedPostStartHook，日志 `liburma.so.0: cannot open shared object file`

**根因**：Ascend950DT 的 npu-smi 依赖 `liburma.so.0`（`umdk-urma-lib` RPM），安装在 `/usr/lib64`。workflow pod 只挂了 `/usr/local/Ascend/driver`，没挂 `/usr/lib64`。

**解决**：ConfigMap 加 hostPath volume `/usr/lib64` → 容器 `/usr/lib64`

---

## 五、配置管理

### 5.1 Resource name 不匹配

**现象**：Volcano `Unschedulable: huawei.com/ascend-a5 not found`

**根因**：ConfigMap 里写 `huawei.com/ascend-a5`，节点 device plugin 注册的是 `huawei.com/npu`

**解决**：ConfigMap 全部改为 `huawei.com/npu`

---

### 5.2 Weight NFS 新节点不可见

**现象**：workflow pod 在 lab-03/04 上 `FailedMount: /mnt/weight/vllm-ascend is not a directory`

**根因**：lab-01/02 有 `/mnt/weight` NFS，后加的 03/04 没挂这个 NFS

**解决**：改 ConfigMap weight 路径为 `/mnt/share/vllm-ascend/weight`（共享 NFS，所有节点都有），type=DirectoryOrCreate

---

### 5.3 CI deployment PR values.yaml 对齐 A3

**现象**：多次代码 review 要求 values.yaml 与 A3 完全对齐。

**解决**：最终方案：直接从 `linux-aarch64-a3-8/values.yaml` 复制，仅替换标签（`a3-8`→`950dt-n`，`ascend-1980`→`ascend-950dt`，`gy-005`→`shanghai-001`），其余一字不改。ConfigMap 从 cn12-001 模板复制。

---

## 六、Service 管理与迁移

### 6.1 Resource-api + Vue-frontend 部署

**状态**：已在 master 节点部署 `resource-api` (FastAPI) 和 `vue-frontend` (Vue.js + Nginx)，各 3 副本，arc-system namespace。

### 6.2 Admin123 服务节点

**迁移内容**：resource-api、ARC controller、listeners、secrets-manager、imagepullsecret-patcher、nginx-pypi-cache（PyPI/APT/Rust/YUM 缓存代理）

**配置要点**：
- DNS 顺序：114.114.114.114 在前（优先），178.27.1.100 在后
- containerd mirror: daocloud + aliyuncs
- 无 storage provisioner：PVC 改 hostPath
- Listeners：hostNetwork 已移除，避免 port 8080 冲突

---

## 关键架构决策记录

| 决策 | 原因 |
|------|------|
| Cilium 用 BPF masquerade 而非 iptables | iptables 规则对 `cilium_host` 流量跳过了 SNAT |
| kube-proxy-replacement=false | BPF service 路由不工作时，kube-proxy iptables 作为 fallback |
| Listener/runner 临时用 dnsPolicy:None | CoreDNS 修复前的过渡方案，直接走 114.114.114.114 |
| 证书加所有节点 IP + ELB IP | 避免 TLS 握手失败，支持多入口 |
| values.yaml 100% 从 A3 复制 | 最小化差异，降低维护成本 |
| Helm 只装一次，不动 | 避免 scale set ID 变化导致 job orphan |
| OpenEuler containerd 用 v1.6 配置格式 | 适配系统自带版本 |

---

## 待完成事项

| # | 事项 | 优先级 |
|---|------|:--:|
| 1 | ArgoCD 注册集群 + PR #1055 合入 | 高 |
| 2 | lab 节点 NTP 永久配置 | 中 |
| 3 | CoreDNS 转发回包路由彻底修复（去掉 dnsPolicy:None workaround） | 中 |
| 4 | Volcano 部署（镜像已就绪） | 中 |
| 5 | Device Plugin + NodeD 部署 | 中 |
