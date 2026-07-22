# Shanghai Cluster (openmerlin-shanghai-001) 部署手册

## 集群架构

| 层级 | 节点 | 位置 | 架构 | 规格 |
|------|------|------|------|------|
| 云上 | master-01/02/03 | 华为云 ECS | x86_64 | 4C8G, Ubuntu 22.04 |
| 云下 | lab-worker-01/02/03/04 | 实验室 | aarch64 | 384C/1.5TB, 8× Ascend950DT, openEuler 24.03 |
| 服务 | admin123 (192.168.13.107) | 实验室 | x86_64 | 56C/251G, Ubuntu 22.04 |

**网络**：

| 网段 | 接口 | 用途 |
|------|------|------|
| 10.254.1.0/24 | eth1（master）/ enp34s0f1（lab） | 管理面 |
| 10.254.9.0/24 | eth0（master） | 服务面 |
| 192.168.8.0/21 | enp34s0f1（lab） | 云下面管理 |
| 178.27.0.0/18 | data0（lab） | 云下面数据、NFS |

**ELB**：

| ELB | 地址 | 用途 |
|-----|------|------|
| 管理面 | `115.175.0.82:6443`（内 `10.254.1.33`） | 对外 API server |
| 服务面 | `10.254.9.147:6443` | Pod 内部访问 |

---

## 一、前期网络准备

### 1.1 准备云上、云下资源

1. 获取云下计算节点 IP、地址、网关、公网 IP
2. 准备云上各 master IP、VPN 网关、管理面 IP、业务面 IP 和 VPC（选择地理位置接近的 Region）

### 1.2 开通 GRE 防火墙

1. 将云上 IP 和云下公网 IP 分别填入目的端和源端，打通双向
2. 推动审批流程

### 1.3 配置 VPN

1. 云上和云下都配置 IPsec VPN，确保所有参数一一匹配

### 1.4 安全组修改

1. 修改 ECS 安全组，将云上和云下小网段加入入方向放通规则

### 1.5 验证并做安全加固

---

#### 遇到的问题

##### 1. 回程路由不通——子网段重复

**现象**：网络配置完后测试不通，只有去的包，没有回的包。

**根因**：路由器回程子网段与云上服务面网段重复，都在 `10.0.9.0/24`。回程路由找到多条匹配，导致回包错误路由。

**解决**：切换为 `10.254.9.0/24` 网段后回程路由唯一，得以解决。

---

## 二、云上搭建 K8s

### 2.1 云上搭建 K8s 集群

1. 三台 master 节点执行系统准备（hostname、swap off、kernel modules、sysctl）
2. 安装 containerd v2.2.6，配置 SystemdCgroup + 阿里云镜像加速（`registry.aliyuncs.com/google_containers`）
3. `kubeadm init`：API server 绑定管理面 IP `10.254.1.187`，control-plane-endpoint 同地址
4. 安装 Cilium CNI（native routing + BPF masquerade + NodePort）
5. 加入 master-02/03 作为 control-plane 节点
6. 安装 ARC Controller（actions-runner-controller 0.14.2）

### 2.2 安装组件服务

1. 部署 resource-api（FastAPI）和 vue-frontend（Vue.js + Nginx）到 arc-system namespace
2. 安装 resource-deploy-core 仓库的前后端镜像

### 2.3 证书与 ELB 配置

1. 更新 kubeadm-config，将管理面 ELB `115.175.0.82` 和服务面 ELB `10.254.9.147` 加入 certSANs
2. 三台 master 重新生成 API server 证书并重启
3. 更新 cluster-info ConfigMap 和 kube-proxy ConfigMap 的 server 地址为 ELB

---

#### 遇到的问题

##### 1. Cilium cluster-pool CIDR 与 kubeadm CIDR 不一致

**现象**：Pod 实际分配 IP 为 `10.0.x.x`，而非 kubeadm 指定的 `10.244.0.0/16`。

**根因**：Cilium 默认 `cluster-pool-ipv4-cidr: 10.0.0.0/8`，kubeadm 的 `--pod-network-cidr` 只影响 kube-proxy 和 CoreDNS，Cilium 自身 IPAM 不受其控制。

**解决**：将 `ipv4-native-routing-cidr` 设为 `10.0.0.0/8` 与实际 Pod IP 段对齐。

---

##### 2. Flannel CNI 残留冲突

**现象**：CoreDNS pod 创建失败，日志 `plugin type="flannel" failed: open /run/flannel/subnet.env: no such file or directory`。

**根因**：旧集群的 flannel CNI 配置文件存在于 `/etc/cni/net.d/`，kubelet 在 Cilium 写入其 CNI 配置前先加载了 flannel。

**解决**：删除 `/etc/cni/net.d/*` 内容，重启 kubelet。

---

##### 3. 证书不含 ELB IP 致 TLS 验证失败

**现象**：lab 节点 `kubeadm join 10.254.9.147:6443` 报 `x509: certificate is valid for 10.96.0.1, 10.254.1.187, not 10.254.9.147`。

**根因**：`kubeadm init` 时证书仅包含 control-plane-endpoint IP。

**解决**：更新 certSANs 列表，包含所有节点的管理和服务 IP 以及两个 ELB IP，重新生成证书并分发到全部 master。

---

##### 4. 证书重新生成时丢失老 SAN 致 API server CrashLoop

**现象**：为新 ELB 重新生成证书后 API server 全部 CrashLoopBackOff，kubectl 报证书不包含 `10.254.1.187`。

**根因**：`kubeadm init phase certs apiserver` 不自动合并已有 SAN，完全按 ConfigMap 中的列表重新生成。写入新增 IP 时遗漏了原有 IP。

**解决**：每次修改 certSANs 必须保留所有已有 IP。最终 certSANs 列表：`10.254.1.187, 10.254.1.232, 10.254.1.25, 10.254.9.49, 10.254.9.229, 10.254.9.85, 10.254.9.147, 115.175.0.82`

---

##### 5. cluster-info 和 kube-proxy ConfigMap 指向老地址

**现象**：lab 节点 join 时尝试连接 `10.254.1.187:6443`（不通），lab 节点 kube-proxy 日志持续超时。

**根因**：这两个 ConfigMap 中硬编码了 kubeadm init 时的 server 地址，ELB 添加后未同步。

**解决**：手工更新两个 ConfigMap 中的 server 地址为 ELB `10.254.9.147:6443`。

---

## 三、云下机器系统准备与软件安装

### 3.1 检查云下机器情况

1. 确认操作系统为 openEuler 24.03 LTS-SP4，架构 aarch64
2. 确认 Ascend950DT 驱动和 CANN 9.1.0 已安装（`npu-smi info` 可见 8 张卡）
3. 确认节点公网出流量可达（`curl www.baidu.com` 成功）
4. 确认共享存储 `/mnt/share` 和 `/mnt/weight` NFS 挂载可用

### 3.2 云下系统准备

1. 设置唯一 hostname（`lab-worker-01`、`lab-worker-02` 等）
2. 关闭 swap（OpenEuler 默认开启）
3. 创建 `/run/systemd/resolve/resolv.conf` 软链接（OpenEuler 无 systemd-resolved）
4. 安装 containerd v1.6（OpenEuler 自带），配置 SystemdCgroup + 镜像代理（daocloud + aliyuncs）
5. 从 master-01 下载 aarch64 版 kubeadm/kubelet/kubectl RPM 包，scp 传输后本地 rpm 安装
6. `kubeadm join` 通过 ELB `10.254.9.147:6443` 加入集群

### 3.3 云下安装 Ascend 组件

1. 安装 Ascend Docker Runtime（containerd 集成场景）
2. 部署 Device Plugin DaemonSet（volcanoType=true, presetVirtualDevice=true）
3. 部署 NodeD DaemonSet
4. 配置 Volcano 调度器

### 3.4 验证

1. `kubectl get nodes` 确认节点 Ready
2. `kubectl describe node <name> | grep npu` 确认 NPU 资源可见
3. Device Plugin + NodeD pod Running

---

#### 遇到的问题

##### 1. OpenEuler 无 systemd-resolved

**现象**：Pod sandbox 创建失败，kubelet 日志 `open /run/systemd/resolve/resolv.conf: no such file or directory`。

**根因**：OpenEuler 24.03 不使用 systemd-resolved，kubelet 默认配置引用该路径。

**解决**：`mkdir -p /run/systemd/resolve && ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf`

---

##### 2. containerd v1.6 与 v2.x 配置格式不同

**现象**：从 master 复制 containerd 配置后启动失败或 mirror 不生效。

**根因**：OpenEuler 自带 v1.6，使用旧版 config 格式。Registry mirror 在 `[plugins."io.containerd.grpc.v1.cri".registry.mirrors]` 段，不同于 v2.x 的 `certs.d` 目录。`sandbox_image` 用双引号格式。

**解决**：使用 `containerd config default` 生成 v1.6 默认配置，再手动添加 mirror 和 sandbox 修改。

---

##### 3. Lab 节点外网下载软件包不稳定

**现象**：`yum install kubeadm` 失败，`Could not resolve host: mirrors.aliyun.com`。

**根因**：lab 节点 DNS 解析正常，但到某些 CDN 的 TCP 连接不通。

**解决**：从有外网的 master-01 下载 aarch64 RPM 包，通过 scp 传输。用 `rpm -ivh --nodeps` 安装（`--nodeps` 跳过 kubernetes-cni 依赖，Cilium 自带 CNI 插件）。kubelet 配置 node-ip 指向云下管理 IP。

---

##### 4. 两节点 hostname 相同致相互覆盖

**现象**：加入两台 lab 节点后 `kubectl get nodes` 只显示一个 `localhost.localdomain`。

**根因**：两台初始 hostname 相同，K8s 以 hostname 为节点唯一标识。

**解决**：加入集群前设置唯一 hostname。

---

##### 5. Ascend Docker Runtime 与 Device Plugin 版本不匹配

**现象**：NPU 容器启动失败 `dcmi init failed, error code: -8255`。

**根因**：Runtime v7.0.RC1 仅支持 DCMIv1 API，Device Plugin v26.x 使用 DCMIv2。Ascend950DT 需要 v26.x Runtime。

**解决**：升级 Runtime 到 v26.1.0.beta.2。注意：installer 文件名必须包含 `aarch64`。

---

##### 6. 资源名不一致——ConfigMap 写 `huawei.com/ascend-a5` 但节点注册 `huawei.com/npu`

**现象**：Volcano 调度报 `Unschedulable: huawei.com/ascend-a5 not found`。

**根因**：ConfigMap 中资源名与 Device Plugin 实际注册的不一致。

**解决**：所有 ConfigMap 和 values 中的 NPU 资源名统一改为 `huawei.com/npu`。

---

##### 7. presetVirtualDevice=false 导致 Device Plugin CrashLoop

**现象**：Device Plugin CrashLoop，日志 `only 310p, 910a2 and 910a3 support presetVirtualDevice false`。

**根因**：Ascend950DT 只支持静态虚拟化。

**解决**：保持 `presetVirtualDevice=true`，配置 vnpu.cfg `dev0:0-7` 实现 1×8 卡虚拟设备。

---

##### 8. liburma.so.0 缺失导致 workflow pod PostStartHook 超时

**现象**：容器 Started 后 300s FailedPostStartHook，日志 `liburma.so.0: cannot open shared object file`。

**根因**：Ascend950DT 的 `npu-smi` 依赖 `/usr/lib64` 下的 `liburma.so.0`，workflow pod 未挂载该路径。

**解决**：ConfigMap 添加 hostPath volume `/usr/lib64` → 容器 `/usr/lib64`。

---

##### 9. Volcano NPU 插件无默认 handler

**现象**：NPU job 调度失败 `validNPUJob failed: no policy handler registered`。

**根因**：Volcano NPU 插件需要 pod annotation 指定调度策略，950DT 无预配置 handler。

**解决**：PodTemplate 添加 annotation `huawei.com/schedule_policy: chip1-node8`。

---

## 四、云上云下实现联通（Pod 网络与 DNS）

此为整个部署最核心也最耗时的阶段，涉及 3 条链路 7 个子问题。

### 4.1 DNS 链路分析

```
Pod (10.0.x.x)
  → CoreDNS ClusterIP (10.96.0.10)     [链路1]
  → CoreDNS pod → forward → 上游DNS     [链路2]
  → 上游DNS回复 → 回不到 Pod             [链路3]
```

### 4.2 链路修复

1. **链路 1 — Cilium kube-proxy replacement 不工作**：关闭 kube-proxy replacement，回退到 iptables 模式。验证：Pod 内能 `curl https://10.96.0.1:443` 返回 `ok`

2. **链路 2 — CoreDNS 转发到不可达上游**：迭代 3 次修正 forward 目标，最终恢复 `forward . /etc/resolv.conf`。lab 节点 DNS 顺序调整为 `114.114.114.114` 在前、`178.27.1.100` 在后

3. **链路 3 — 回包路由不通（Cilium masquerade）**：启用 BPF masquerade + NodePort。根因是 iptables masquerade 规则的 `oifname != "cilium_*"` 条件跳过了 `cilium_host` 出口的流量，BPF 层面不受此限制

### 4.3 临时绕过方案

在 DNS 完全修复前，给 ARC controller、listener、runner 等关键 Pod 加 `dnsPolicy: None` + 直接指定 `114.114.114.114` 作为 DNS。

### 4.4 时钟同步

lab 节点时钟比实际快 8 小时，导致 GitHub JIT token 的 `nbf` 校验失败（token 看起来在未来生效），runner 创建 session 失败 → 退出 → listener 重新创建 → 无限循环。

从 master-01 同步正确时间后修复。遗留问题：需配置 NTP 永久解决。

---

#### 遇到的问题

##### 1. Cilium kube-proxy replacement BPF 路由不正常

**现象**：Pod 内 `curl https://10.96.0.1:443` 超时。CoreDNS kubernetes 插件 `Still waiting on: kubernetes`，无法初始化。

**根因**：`kube-proxy-replacement: true` 时 Cilium 用 BPF 处理 Service IP 路由，但实际未能正确工作。

**解决**：关闭 kube-proxy replacement (`false`)，回退到 kube-proxy iptables 处理 Service IP。

---

##### 2. CoreDNS 转发上游 DNS 不通

**现象**：Pod 内 DNS 查询到达 CoreDNS 后 SERVFAIL。

**根因**：3 次迭代——初始 `114.114.114.114` 从 lab 不可达；改为 `178.27.1.100` 可达但回包路由不通；最终恢复默认 `/etc/resolv.conf` 等链路 3 修好后生效。

**解决**：最终方案为 CoreDNS 用 `/etc/resolv.conf`，lab 节点 DNS 优先 `114.114.114.114`。

---

##### 3. Cilium iptables masquerade 跳过 `cilium_host` 出口流量

**现象**：host 上 `nslookup api.github.com <coredns-pod-ip>` 成功，Pod 内同等查询超时。

**根因**：iptables masquerade 规则 `oifname != "cilium_*"` 导致通过 `cilium_host` 出口的 pod 流量未被 SNAT。Pod 源 IP (10.0.x.x) 在数据面网络 (178.27.0.0/18) 无回程路由。BPF masquerade 不受此接口过滤限制。

**解决**：开 `enable-bpf-masquerade: true` + `enable-node-port: true`（后者是前者依赖，缺少会导致 CrashLoop）。

---

##### 4. Cilium agent CrashLoop——BPF masquerade 依赖 NodePort

**现象**：单独启用 BPF masquerade 后 Cilium agent CrashLoop，日志 `BPF masquerade requires NodePort`。

**根因**：BPF masquerade 功能依赖 NodePort BPF 基础设施。

**解决**：`enable-bpf-masquerade` 和 `enable-node-port` 必须同时设为 `true`。

---

##### 5. CoreDNS pod 长时间 0/1 Ready

**现象**：CoreDNS pod `0/1 Running`，readiness probe 503。

**根因**：CoreDNS kubernetes 插件启动需连接 API server。Cilium 未就绪时 Service IP 路由不通，插件进入等待循环。

**解决**：等 Cilium agent 全部 Ready 后，重启 CoreDNS pod 即可。

---

##### 6. Lab 节点时钟偏差 8 小时致 runner 无限循环

**现象**：Runner pod 日志 `token not valid until 21:43:24, server time is 13:43:09`，runner 不断创建-失败-退出-重建。

**根因**：lab 节点时钟比实际快 8 小时。GitHub JIT token 的生效时间 (`nbf`) 基于实际 UTC，但 runner 用容器时间校验时认为 token 还未生效。

**解决**：`date -s` 同步到 master 时间。遗留需配置 NTP 永久修复。

---

##### 7. 反复重装 Helm 导致 scale set ID 变化、job 孤儿

**现象**：多次 `helm uninstall/install` 后 GitHub job 永远 QUEUED。

**根因**：每次重装向 GitHub 注册新 scale set ID，旧 job 绑定在旧 ID 上，GitHub 不会自动迁移。

**解决**：确认配置后只安装一次，不再卸载。生产环境依赖 ArgoCD GitOps 管理。

---

## 五、后续维护

### 5.1 GitOps 接入

1. 在 ci-deployment 仓库新建 `projects/vllm-project/vllm-ascend/config-shanghai/`（namespace、SA、RBAC、Secret、ConfigMaps）
2. 新建 `linux-aarch64-950dt-{2,4,8}-shanghai/`（runner scale set Helm values，从 A3 直接复制仅改标签）
3. 新建 `argocd/clusters/shanghai-001/vllm-ascend.yaml`（ArgoCD Application）
4. 提 PR 合入

### 5.2 ArgoCD 注册

1. 使用 kubeconfig（指向管理面 ELB `115.175.0.82:6443`）注册集群
2. 白名单放行 ArgoCD IP

### 5.3 Service 迁移

1. 新增 admin123（192.168.13.107）作为专用服务节点（x86_64, 56C/251G）
2. 迁移 resource-api、ARC controller、listeners、secrets-manager、imagepullsecret-patcher 从 master 到 admin123
3. 部署 nginx-pypi-cache（PyPI/APT/Rust/YUM 缓存代理）
4. 配置要点：DNS 优先 `114.114.114.114`、containerd mirror daocloud+aliyuncs、PVC 改 hostPath

### 5.4 Weight NFS 路径调整

后加入的 lab-03/04 无 `/mnt/weight` NFS 挂载。ConfigMap 中 weight 路径改为 `/mnt/share/vllm-ascend/weight`（所有节点共享），`type: DirectoryOrCreate`。

### 5.5 Values.yaml 与 A3 对齐

PR 中 values.yaml 直接从 A3-8 复制，仅改 3 处标签避免手工编辑引入格式偏差：
```
a3-8 → 950dt-n
ascend-1980 → ascend-950dt
gy-005 → shanghai-001
```

### 5.6 遗留事项

| # | 事项 | 优先级 |
|---|------|:--:|
| 1 | ArgoCD 注册集群 + PR 合入 | 高 |
| 2 | lab 节点 NTP 永久配置 | 中 |
| 3 | CoreDNS 回包路由永久修复（去掉 dnsPolicy workaround） | 中 |
| 4 | Volcano + Device Plugin + NodeD 完整部署 | 中 |

---

## 附录：排查模式速查

| 排查模式 | 适用场景 |
|----------|----------|
| DNS 链路分段验证（Pod→CoreDNS→上游→回包） | 任何 Pod 内网络不通 |
| 证书 SAN 列表必须完整，修改后三台 master 都需重新生成+重启 | 添加新入口 IP |
| 时钟偏差 → JIT token nbf 校验失败 | Runner 无限循环 |
| Helm 重装 → scale set ID 变化 | GitHub job 永远 queued |
| Docker Registry /v2/ 返回 401 = 正常认证流程 | 误判为镜像仓库故障 |
| OpenEuler 与 Ubuntu 差异（systemd-resolved、containerd 版本、包管理器） | 云下节点部署 |
| values.yaml 从已有配置直接复制，不手工编辑 | 避免格式和 lint 错误 |
