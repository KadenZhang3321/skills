# 华为云 + 线下 + VPN K8s 集群问题汇总

> 集群：3 master（Ubuntu 22.04 x86_64）+ 4 worker（openEuler 24.03, aarch64, VPN 接入）+ 1 服务节点 admin123（Ubuntu 22.04, x86_64, VPN 接入）
<br>
CNI：Cilium（tunnel / VXLAN 模式）
<br>
K8s：v1.32.13
<br>
处理时间：2026-07-16 ~ 2026-07-22
<br>
状态：**所有问题均已修复并验证**

---

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

**ELB**：管理面 `115.175.0.82:6443`（内 `10.254.1.33`），服务面 `10.254.9.147:6443`。

**VPN**：IPsec 站点间 VPN，仅放行节点网段（10.254.9.0/24 ↔ 192.168.8.0/21），**不放行 Pod 网段**。

---

## 总览

| # | 负责内容 | 责任对象 |
|---|------|------|
| 1 | 云下实验室物理机器 | 对应业务部门 |
| 2 | 云下实验室机器系统OS安装 | 对应业务部门 | 
| 3 | 云下实验室机器mindcluster组件安装 | 最好找mindcluster部门同事安装 | 
| 4 | 云上云下防火墙申请 | 基础设施开发 | 
| 5 | 云上云下VPN配置 | 基础设施运维与装备部同事 |
| 6 | 云上k8s搭建 | 基础设施 |
| 7 | 云上DNS网络配置 | 基础设施运维 |
| 8 | 云下节点加入云上K8s | 基础设施开发 |

--
## 软件/安装组件/插件/服务需求
| # | 用途 | 云上 | 云下 |
|---|------|------|------|
|Kubernetes v1.32.13 | 容器编排平台，集群基础设施  | ✓ | ✓ |
| Cilium v1.17.2（tunnel/VXLAN）   | CNI 网络插件，跨节点 Pod 通信 | ✓ | ✓ |
| CoreDNS                              | 集群内部 DNS，Service 发现        |  ✓   |  —   |
| etcd（3 成员 HA）                     |K8s 数据存储，配置和状态同步    |  ✓   |  —   |
| ARC Controller 0.14.201               |GitHub Actions Runner 生命周期管理    |  ✓   |  —   |
| resource-api + vue-frontend             |集群资源管理后台 + 前端面板  |  ✓   |  —   |
| Volcano（controller/scheduler/admission）| NPU 感知的批量调度器，分配 NPU 资源  |  ✓   |  —   |
| npu-scheduler（自定义 scheduler）        | Ascend 自定义调度器，过滤/排序 NPU 节点  |  ✓   |  —   |
| secrets-manager                           |从 Vault 自动同步 GitHub Token 等密钥|  ✓   |  —   |
| imagepullsecret-patcher                  |自动为 ServiceAccount 注入镜像仓库认证 |  ✓   |  —   |
| nginx-pypi-cache                          |PyPI/APT/Rust/YUM 缓存代理，加速依赖下载 |  ✓   |  —   |
| containerd                               |容器运行时    |  ✓   |  ✓   |
| Ascend Docker Runtime v26.1.0.beta.2    | NPU 设备容器化支持，自动挂载驱动和依赖    |  —   |  ✓   |
| Ascend Device Plugin                    |注册 huawei.com/npu 资源，设备发现、健康检查、分配  |  —   |  ✓   |
| CANN 9.1.0 + NPU 驱动                  |昇腾 AI 计算框架和芯片驱动   |  —   |  ✓   |
| Ascend950DT（8×96GB HBM）               |昇腾训练芯片，单卡 96GB HBM，集群计算资源  |  —   |  ✓   |
|  NFS 共享存储                 |pip 缓存 + 模型权重共享存储  |  —   |  ✓   |



---

## 一、前期网络准备（具体操作看https://wiki.huawei.com/domains/987/wiki/16328/WIKI2026071511873767 ）

### 1.1 准备云上、云下资源 （涉及人员：基础设施 & 业务部门 & 装备部）

1. 获取云下计算节点 IP、地址、网关、公网 IP （基础设施开发）
2. 准备云上各 master IP、VPN 网关、管理面 IP、业务面 IP 和 VPC（选择地理位置接近的 Region） （基础设施运维）

### 1.2 开通 GRE 防火墙

1. 将云上 IP 和云下公网 IP 分别填入目的端和源端，打通双向，在防火墙端口位置需要特别注意最后两个特俗端口，不是输入进去而是选择的特俗端口 （基础设施开发）
2. 推动审批流程 （基础设施开发）

### 1.3 配置 VPN

1. 云上和云下都配置 IPsec VPN，确保所有参数一一匹配 （基础设施运维 & 装备部 & 实验室机器运维）

### 1.4 安全组修改

1. 修改 ECS 安全组，将云上和云下小网段加入入方向放通规则 （基础设施运维）

### 1.5 验证并做安全加固

---

#### 遇到的问题

##### 1. 回程路由不通——子网段重复

**现象**：网络配置完后测试不通，只有去的包，没有回的包。

**根因**：路由器回程子网段与云上服务面网段重复，都在 `10.0.9.0/24`。回程路由找到多条匹配，导致回包错误路由。

**解决**：切换为 `10.254.9.0/24` 网段后回程路由唯一，问题解决。

---
 
## 二、云上搭建 K8s （涉及人员：基础设施）

### 2.1 K8s 集群初始化

1. 三台 master 节点系统准备（hostname、swap off、kernel modules、sysctl） （基础设施开发）
2. 安装 containerd v2.2.6，配置 SystemdCgroup + 阿里云镜像加速 （基础设施开发）
3. `kubeadm init`：API server 绑定管理面 IP `10.254.1.187` （基础设施开发）
4. 安装 Cilium CNI（最终采用 tunnel/VXLAN 模式，见第四节） （基础设施开发）
5. 加入 master-02/03 作为 control-plane 节点 （基础设施开发）

### 2.2 组件服务安装

1. 部署 resource-api（FastAPI）和 vue-frontend（Vue.js + Nginx），arc-system namespace （基础设施开发）
2. 安装 ARC Controller（actions-runner-controller 0.14.2） （基础设施开发）
3. 部署 secret 和 imagepullsecret-patch 服务 （基础设施开发）

### 2.3 证书与 ELB 配置

1. 将所有需要访问 API server 的 IP（管理面、服务面、ELB）加入 `apiServer.certSANs` （基础设施开发）
2. 三台 master 重新生成 API server 证书并重启 （基础设施开发）
3. 更新 cluster-info 和 kube-proxy ConfigMap 中的 server 地址为 ELB （基础设施开发）

---

#### 遇到的问题

##### 1. Cilium cluster-pool CIDR 与 kubeadm CIDR 不一致

**现象**：Pod 实际分配 IP 为 `10.0.x.x`，而非 kubeadm 指定的 `10.244.0.0/16`。

**根因**：Cilium 默认 `cluster-pool-ipv4-cidr: 10.0.0.0/8`，不受 kubeadm `--pod-network-cidr` 控制。

**解决**：后续配置（如 masquerade、routing 规则）均以 Cilium 实际使用的 `10.0.0.0/8` 为准。

##### 2. 证书不含 ELB IP 致 TLS 验证失败

**现象**：lab 节点 `kubeadm join` 报 `x509: certificate is valid for ..., not 10.254.9.147`。

**根因**：kubeadm init 时证书仅含 control-plane-endpoint 指定的 IP。

**解决**：更新 certSANs 包含所有节点管理/服务 IP 和两个 ELB IP，在三台 master 重新生成证书并重启 API server。

**最终 certSANs**：`10.254.1.187, 10.254.1.232, 10.254.1.25, 10.254.9.49, 10.254.9.229, 10.254.9.85, 10.254.9.147, 115.175.0.82`

##### 3. 证书重新生成时丢失老 SAN 致 API server CrashLoop

**现象**：为新 ELB 重新生成证书后 API server 全部 CrashLoopBackOff。

**根因**：`kubeadm init phase certs apiserver` 不自动合并已有 SAN，完全按 ConfigMap 中列表重新生成。某次只写入新 IP 而遗漏了 `10.254.1.187`。

**解决**：每次修改 certSANs 前确保所有 IP 都在列表中。生成后分发到所有 master 并重启 API server。

##### 4. cluster-info 和 kube-proxy ConfigMap 指向老地址

**现象**：lab 节点 join 时连接 `10.254.1.187:6443` 不通，kube-proxy 持续超时。

**根因**：ConfigMap 中 hardcoded 初始 server 地址，ELB 添加后未同步。

**解决**：手工更新两个 ConfigMap 为 ELB `10.254.9.147:6443`。

##### 5. 云下子网无法访问外网镜像仓库

**现象**：lab 节点 `yum install kubeadm` 失败，`registry.k8s.io` 和 `quay.io` 镜像拉取超时。

**解决**：从 master-01 下载 aarch64 RPM 包 scp 传输；所有节点 containerd 配置 阿里云（`registry.aliyuncs.com`）和 daocloud（`docker.m.daocloud.io`）镜像代理。

---

## 三、云下机器系统准备与软件安装

### 3.1 检查云下机器情况 （基础设施开发）

1. 确认 openEuler 24.03 LTS-SP4, aarch64 
2. 确认 Ascend950DT 驱动和 CANN 9.1.0 已安装（`npu-smi info` 可见 8 张卡）
3. 确认共享存储 `/mnt/share` 和 `/mnt/weight` NFS 可用

### 3.2 云下系统准备 （基础设施开发）

1. 设置唯一 hostname（避免 `localhost.localdomain` 冲突）
2. 关闭 swap
3. 创建 `/run/systemd/resolve/resolv.conf` 软链接（OpenEuler 无 systemd-resolved）
4. 安装 containerd v1.6，配置镜像代理和 sandbox 镜像
5. 从 master-01 scp 传输 kubeadm RPM 包并 rpm 安装
6. `kubeadm join` 通过 ELB 加入集群

### 3.3 云下安装 Ascend 组件 （基础设施开发 & mindcluster 同事）

1. 安装 Ascend Docker Runtime（升级到 v26.1.0.beta.2 匹配 Device Plugin）
2. 部署 Device Plugin DaemonSet（volcanoType=false, presetVirtualDevice=true）—— 已修复（见问题 #10）
3. 安装 volcano 昇腾插件 —— **未安装**（暂不需要，volcanoType 已关）

### 3.4 接入 K8s（基础设施开发）

1. 验证节点 Ready + NPU 资源可见
2. Device Plugin + NodeD pod Running

---

#### 遇到的问题

##### 1. OpenEuler 无 systemd-resolved 致 Pod sandbox 创建失败

**现象**：kubelet 日志 `open /run/systemd/resolve/resolv.conf: no such file or directory`。

**解决**：`mkdir -p /run/systemd/resolve && ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf`

##### 2. containerd v1.6 与 v2.x 配置格式不同

**现象**：从 master 复制配置后 mirror 不生效或 containerd 启动失败。

**根因**：OpenEuler 自带 v1.6，使用旧版 TOML 格式。Registry mirror 在 `[plugins."io.containerd.grpc.v1.cri".registry.mirrors]` 段，sandbox_image 用双引号。

**解决**：使用 v1.6 默认配置生成后手动修改。

##### 3. 两节点 hostname 相同致相互覆盖

**现象**：加入两台后只显示一个 `localhost.localdomain`。

**解决**：加入前设唯一 hostname。

##### 4. Ascend Docker Runtime 版本与 Device Plugin 不匹配

**现象**：NPU 容器 `dcmi init failed, error code: -8255`。

**根因**：v7.0.RC1 仅 DCMIv1，Device Plugin v26.x 用 DCMIv2。需 v26.x Runtime。

**解决**：升级到 v26.1.0.beta.2（**坑**：installer 文件名必须含 `aarch64`）。

##### 5. 资源名不一致——ConfigMap `ascend-a5` vs 节点 `npu`

**现象**：Volcano `Unschedulable: huawei.com/ascend-a5 not found`。

**解决**：全部 ConfigMap 改为 `huawei.com/npu`。

##### 6. presetVirtualDevice=false 致 Device Plugin CrashLoop

**现象**：`only 310p, 910a2 and 910a3 support presetVirtualDevice false`

**根因**：Ascend950DT 仅支持静态虚拟化。

**解决**：保持 `presetVirtualDevice=true`，vnpu.cfg `dev0:0-7`。

##### 7. liburma.so.0 缺失致 workflow PostStartHook 超时

**现象**：容器 Started 后 300s FailedPostStartHook。

**根因**：npu-smi 依赖 `/usr/lib64/liburma.so.0`，pod 未挂载。

**解决**：ConfigMap 加 hostPath `/usr/lib64` → `/usr/lib64`。

##### 8. 安装 Device Plugin 之后报DCMI一直重试错误

**现象**：安装 Device Plugin 插件之后报DCMI一直重试错误

**根因**：最新版本对A5机器仍缺乏某些配置

**解决**：联系mindclust 同事排查，补上三个点的对应缺失参数。

##### 9. volcano 调度器无法使用

**现象**：切换volcano调度器之后，runner无法正常调起workflow pod/workflow pod一直pending

**根因**：volcano调度器对A5机器适配问题

**解决**：联系mindclust 同事排查，需要再configmap 加上annotation的key。

##### 10. Device Plugin volcanoType=true 致 1/2/4 卡 Pod 全部 UnexpectedAdmissionError（仅 8 卡正常） 🔥

**发现时间**：2026-07-29，持续到 2026-07-30 修复

**触发条件**：ArgoCD 同步了 Volcano 配置调整（7/29 11:00 左右），虽然这不是根因但排查初期误导了方向（详见排查过程第 6 步）。

---

**现象**：

Runner pod（非 NPU）能正常启动，但 workflow pod（请求 NPU）稳定失败：
```
Pod status: Failed (UnexpectedAdmissionError)
Pod was rejected: Allocate failed due to rpc error: code = Unknown desc = not get valid pod, which is unexpected
```

规律：**1、2、4 卡全部报这个错误，只有 8 卡正常 Running。** 与调度器无关（切默认调度器同样失败）。

---

**排查过程**：

1. **检查 Kubelet 事件** — pod 被 `Successfully assigned` 到节点，但立即 `UnexpectedAdmissionError`。说明调度成功，失败在 Kubelet 的 admission 阶段——即 device plugin 的 `Allocate()` gRPC 调用。

2. **检查 device plugin 版本和配置** — 版本 `ascend-k8sdeviceplugin:v26.1.0.beta.2`，daemonset 自 Jul 22 起未重启（pod age 8d）。启动参数：`-volcanoType=true -presetVirtualDevice=true`。vnpu.cfg 内容：
   ```
   vnpu_config_recover:enable
   dev0:0-7    # 8卡虚拟设备
   dev1:0-3    # 4卡虚拟设备（物理 NPU 0-3）
   dev2:4-7    # 4卡虚拟设备（物理 NPU 4-7）
   ```
   vnpu.cfg 全 4 节点一致，创建于 Jul 21，当前内容与当初无变化。

3. **查 device plugin 日志文件**（`/var/log/mindx-dl/devicePlugin/devicePlugin.log`）— 关键发现：最后一条成功 Allocate 在 **7/28 19:59**（4 卡），第一条失败在 **7/29 09:40**。成功日志完整链路：
   ```
   request: ["npu-2","npu-4","npu-3","npu-5"]    ← Kubelet 随机选了 4 个物理 NPU
   vol found: ["npu-0","npu-1","npu-2","npu-3"]   ← filter 匹配到虚拟设备 dev1
   allocate resp env: 0,1,2,3                     ← 分配成功
   ```
   失败日志只有两行：
   ```
   pod add → request: ["npu-4","npu-5"] → no pod passed the filter → retry×3 → not get valid pod
   ```
   filter 找不到 pod，虽然 `pod add` 事件就在前 14ms。

4. **对比历史** — 往前翻日志确认 **7/20-24 期间 1、2、4、8 卡全部正常**，甚至 2 卡也成功（返回值如 `1,2` / `0,1`）。同一个 vnpu.cfg、同一个 device plugin 版本。

5. **排查 Vulcano** — 当时 Volcano scheduler/controllers/admission 恰好在 7/29 11:00 被 ArgoCD 重新 sync（`values.yaml` 有改动），且 scheduler 持续报 `failed to update root queue: admission webhook denied`。这看起来像切入点，但**后续验证排除了 Volcano**：
   - 默认调度器下 2 卡同样失败 → 不是 Volcano 调度器问题
   - 删掉 root queue（仿照正常工作的 GY004 集群） → Volcano 不再报错，但 2 卡依旧失败
   - 给 Volcano 加上 `deviceshare` 插件（AscendMindClusterVNPUEnable） → 无效

6. **排查 fault ConfigMap** — `vcjob-fault-npu-cm` 中 4 个 lab 节点全被标记为 `CardNetworkUnhealthy`，32 个 NPU 全部 `NetworkUnhealthyNPU`。但 `npu-smi info` 确认所有 NPU 硬件正常（Health: OK，温度功耗正常）。device plugin 的 RBAC 有 `configmaps: get, list, watch` 权限，Allocate 时会读这个 ConfigMap。清空后 → 无效。且这个 ConfigMap 在集群上存在了 9 天，而 Allocate 直到 7/29 才首次失败，不是根因。

7. **排查 VNPU 配置** — 尝试 `-presetVirtualDevice=false` → device plugin CrashLoopBackOff，报 `only 310p, 910a2 and 910a3 support to set presetVirtualDevice false`。Ascend950DT 强制 VNPU 模式。

8. **重启 device plugin daemonset**（全 4 节点 rolling restart）→ 无效，新 pod 同样 `no pod passed the filter`。

9. **联系华为 mindcluster 同事分析** — 结论：`-volcanoType=true` 需要配合 Ascend for Volcano 插件使用。插件负责在调度阶段选出具体 NPU 设备并写回 pod annotation，device plugin 在 Allocate 时读这个 annotation。当前 Volcano 只装了原生开源版，没有这个插件 → pod 上无 annotation → filter 找不到 pod。8 卡不需要插件是因为全量分配无选择歧义。

10. **验证修复** — daemonset args 改为 `-volcanoType=false -presetVirtualDevice=true`（关 volcanoType，保留 VNPU）。测试 2 卡、4 卡 pod → ContainerCreating → Running ✅。

---

**根因**：

Device plugin 启动参数 `-volcanoType=true` 告诉它"从 pod annotation 读 NPU 设备选择信息"，但这个信息应由 **Ascend for Volcano 调度插件**写上去。当前集群 Volcano 只装了原生开源版，没有 Ascend NPU 亲和性插件 → pod 上缺少 annotation → device plugin 内 filter（`plugin.go:888`）迭代 pod indexer 找不到匹配 → `no pod passed the filter` → 3 次 retry 后 `plugin.go:1327 not get valid pod`。

8 卡不受影响：全节点 8 卡无需选择，直接全量分配，不经过 filter 逻辑。

---

**关键日志位置**：

device plugin container stdout（filter 失败）：
```
[WARN]  server/plugin.go:888    no pod passed the filter, request device: [npu-2 npu-3], retry: 0
[WARN]  server/plugin.go:888    no pod passed the filter, request device: [npu-2 npu-3], retry: 1
[WARN]  server/plugin.go:888    no pod passed the filter, request device: [npu-2 npu-3], retry: 2
[ERROR] server/plugin.go:1327   not get valid pod
```

device plugin 文件日志（`/var/log/mindx-dl/devicePlugin/devicePlugin.log`，正常 Allocate 对比）：
```
[INFO] request: []string{"npu-2", "npu-4", "npu-3", "npu-5"}
[INFO] vol found: []string{"npu-0", "npu-1", "npu-2", "npu-3"}     ← 7/28 成功有这行
[INFO] allocate resp env: 0,1,2,3;
```

---

**解决**：Device plugin daemonset args 改 `-volcanoType=true` → `-volcanoType=false`，`-presetVirtualDevice=true` 保持不变（Ascend950DT 不支持 `presetVirtualDevice=false`）。

集群当前实际运行参数：
```
device-plugin -volcanoType=false -presetVirtualDevice=true -logFile=/var/log/mindx-dl/devicePlugin/devicePlugin.log -logLevel=0 --enable-healthz=true --healthz-address=11251
```

**涉及组件及版本**：

| 组件 | 镜像 | 备注 |
|------|------|------|
| Device Plugin | `ascend-k8sdeviceplugin:v26.1.0.beta.2` | `imagePullPolicy: Never`，本地预加载 |
| Volcano Controller | `docker.io/volcanosh/vc-controller-manager:v1.12.0-v26.1.0.beta.2` | nodeSelector: master-01 |
| Volcano Scheduler | `docker.io/volcanosh/vc-scheduler:v1.12.0-v26.1.0.beta.2` | nodeSelector: master-02 |
| Volcano Admission | `docker.io/volcanosh/vc-webhook-manager:v1.15.0` | nodeSelector: master-03，与 scheduler/controller 版本不同 |
| NPU Scheduler (ARCSync) | `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/scheduler-plugins:025fc15...` | hostNetwork: true，仅调度 runner pod |

**vnpu.cfg**（全 4 节点一致）：
```
vnpu_config_recover:enable
[vnpu-config start]
dev0:0-7
dev1:0-3
dev2:4-7
[vnpu-config end]
```

**Vulcano 调度器 ConfigMap**（当前已恢复为原生配置，无 deviceshare 插件）：
```yaml
actions: "enqueue, allocate, backfill"
tiers:
- plugins:
  - name: priority
  - name: gang
  - name: conformance
- plugins:
  - name: overcommit
  - name: drf
  - name: predicates
  - name: proportion
  - name: nodeorder
  - name: binpack
```

**参考配置文件**：集群实际运行配置已导出到 `ascend-ci-deployment` 仓库 `docs/clusters/sh-001/reference/` 目录：
- `ascend-device-plugin-daemonset.yaml` — Device Plugin DaemonSet（含修复后的 `volcanoType=false`）
- `vnpu.cfg` — VNPU 虚拟设备配置
- `volcano-scheduler-configmap.yaml` — Volcano 调度器配置
- `README.md` — 组件管理方式说明

**注意**：Device Plugin DaemonSet 不在 ArgoCD 管理范围内，是手动 `kubectl apply` 部署的。如果未来重新 apply 旧 YAML 会覆盖此修复。

##### 11. 云下机器无法连接外网

**现象**：云下机器链接外网完全不通

**根因**：etc/reolve.conf 只包含他们内网的地址，无法解析外网地址

**解决**：etc/reolve.conf 增加公网地址。

---

## 四、云上云下网络联通与 CNI 修复 （基础设施运维）

此阶段是整个部署的核心难点，涉及路由、SNAT、CNI 模式四个层面的问题。

### 4.1 问题一：集群业务 IP 设置异常

**问题**：master 业务网段从 `10.254.1.0/24` 切换到 `10.254.9.0/24` 不彻底。master-02/03 上遗留 4 条指向**旧管理 IP**（`10.254.1.x`）的 pod CIDR 静态路由，走管理网卡 eth1，**绕过绑在业务网卡 eth0 的 Cilium 数据面**；且部分 pod CIDR 路由缺失。

**现象**：跨节点 pod 互不通；`cilium-health` 仅 1/7 reachable；master 间 Node 通但 Endpoints 0/1。

**修复**：
- 删除 master-02/03 上 4 条遗留路由（`10.0.x.0/24 via 10.254.1.x dev eth1`）
- Cilium 切为 tunnel 模式（见 4.4），跨节点 pod CIDR 路由改由 Cilium 自动维护，不再依赖外部静态路由

**效果**：所有远端 pod CIDR 经 `cilium_host`（tunnel 设备）路由，跨节点 pod 全通，`cilium-health` 7/7。

### 4.2 问题二：CoreDNS 服务异常

**问题**：问题是 4.1 的衍生。CoreDNS ClusterIP `10.96.0.10` 被 kube-proxy DNAT 到 master-03 的 pod（`10.0.3.x`），DNS 包走 master-02 上 `10.0.3.0/24 via 10.254.1.25 dev eth1` 这条指向旧管理 IP 的死路由，**绕过 Cilium 被丢**。

**现象**：pod 内 `dig @10.96.0.10 baidu.com` 超时；`dig @10.0.3.202 baidu.com` 超时；所有业务域名无法解析。listener无法调度runner/runner一直在空运行

**修复**：随 4.1 一并修复——删死路由 + 切 tunnel + 重启 cilium，DNS 流量回归 Cilium 数据面。

**效果**：`dig @10.96.0.10 baidu.com` 正常；pod 内业务域名解析恢复。

**补充细节（初始搭建阶段）**：

在路由修复之前，DNS 链路存在 3 个断裂点：
```
Pod → CoreDNS ClusterIP (10.96.0.10)    [断裂点1]
     → CoreDNS forward → 上游DNS          [断裂点2]
     → 上游DNS回复 → 回不到Pod             [断裂点3]
```

- 断裂点 1 因 `kube-proxy-replacement: true` 时 Cilium BPF Service 路由失效。临时关闭 kube-proxy replacement 回退 iptables。
- 断裂点 2 因 CoreDNS 转发到不可达的上游 DNS（初始 `114.114.114.114` 从 lab 不通，改为数据面 DNS `178.27.1.100`）。
- 断裂点 3 因 Pod 出站流量未 SNAT，Pod IP（10.0.x.x）在数据面网络无回程路由。后续切 tunnel + 加 SNAT（见 4.3）统一修复。

### 4.3 问题三：路由与 iptables 规则遗漏

**问题**：两个层面叠加：
- (a) master-02/03 遗留 4 条旧 pod CIDR 静态路由（见 4.1）
- (b) **pod → master 节点 IP / kubernetes service `10.96.0.1:443` 不通**：Cilium 对 master 节点 IP 既不 SNAT 也不走隧道，pod 源 IP（`10.0.x.x`）裸送 underlay。站点间 IPsec 网关只认节点网段（`10.254.9.0/24 ↔ 192.168.8.0/21`），**不认 pod 源 IP** → 丢包。

**现象**：pod 内 `curl https://10.96.0.1:443/version` 超时；`ping 10.254.9.229` 100% 丢包；出口抓包源 IP 仍是 pod IP（未 SNAT）。仅 pod→master 节点 IP 不通，pod→pod、pod→外网均通。

**修复**：
- (a) 删 4 条旧路由（见 4.1）
- (b) 在 4 个 worker + admin123 上加 iptables SNAT 规则：
  ```
  iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -d 10.254.9.0/24 -j MASQUERADE
  ```
  将 pod 源 IP SNAT 成节点 IP，IPsec 网关认可。
- 持久化：worker 用 `firewall-cmd --permanent --direct`（firewalld active），admin123 用 networkd-dispatcher 钩子（Ubuntu 无 firewalld），均验证 reload/重启存活

**效果**：`curl https://10.96.0.1:443/version` 返回 200；ping master IP 全通；出口源 IP 已 SNAT 成节点 IP；规则 reload/重启不丢。

### 4.4 问题四：CNI 组件版本与模式差异

**问题**：Cilium `routing-mode` 原选 **native**（直接路由），但本集群是 VPN 跨站拓扑 + worker 多网卡（enp34s0f1、data0 等）+ Ascend NPU 设备干扰。native 模式需自动探测 direct-routing device（underlay 出口网卡），worker-01/03 探测失败；且 native + `auto-direct-node-routes: false` 依赖外部静态路由，对 VPN 拓扑不友好。

**现象**：worker-01/03 cilium pod CrashLoopBackOff，fatal 日志 `unable to determine direct routing device`；这两台 cilium agent 起不来，其上 pod 网络异常。

**修复**：ConfigMap `routing-mode: native → tunnel`（VXLAN 封装），`kubectl rollout restart ds/cilium`。tunnel 模式不依赖 direct-routing device，跨节点流量经 VXLAN 封装（外层节点 IP），pod CIDR 路由由 Cilium 自维护。

**效果**：cilium 7/7 Running，无 CrashLoop；worker-01/03 自愈；VXLAN 隧道（UDP/8472）正常；MTU 1450。

**补充细节（初始搭建阶段尝试过的方案）**：

初始阶段在 native 模式下尝试过多种修复均未成功：
- 开 `enable-bpf-masquerade: true` + `enable-node-port: true`（BPF masquerade 依赖）：短暂生效但随 VPN 拓扑复杂化失效
- 调整 `devices` 列表加入 lab 节点网卡名（`enp34s0f1`）：未解决根本问题
- 改 `ipv4-native-routing-cidr` 从 `10.244.0.0/16` 到 `10.0.0.0/8`：必要但不充分

最终 **切换为 tunnel 模式** 一劳永逸解决了 native routing 在 VPN 环境的所有兼容性问题。

### 4.5 修复后集群整体状态

- `cilium-health`：7/7 reachable，所有节点 Node 1/1 Endpoints 1/1
- cilium pod：7/7 Running，无 CrashLoop
- pod 内 DNS：正常解析
- pod → kubernetes api service（`10.96.0.1:443`）：通（含新增节点 admin123）
- 跨节点 pod 互访：通
- 4 worker firewalld 端口对齐：`10250/tcp 8472/udp 4240/tcp 30000-32767/tcp`
- SNAT 规则持久化：worker（firewalld permanent direct）+ admin123（networkd-dispatcher 钩子），均验证 reload/重启存活

---

## 五、后续维护
### 5.1 注册github，argocd，在[ascend](https://github.com/opensourceways/ascend-ci-deployment) 仓库部署 （基础设施开发）

### 5.1 openeuler和容器ubuntu的C运行时库不兼容

**现象**：openeuler镜像可通过npusmi-info查看npu信息，但ubuntu镜像不行。

**根因**：openeuler和容器ubuntu的C运行时库不兼容。

**解决**：把ascend950DT的驱动库打包进ubuntu经i选哪个



