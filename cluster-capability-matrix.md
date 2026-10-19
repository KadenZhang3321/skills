> 说明：文中 `/root/...`、`/tmp/opencode/...` 路径为取证时的本地运维机路径；`ascend-ci-deployment` = https://github.com/opensourceways/ascend-ci-deployment 。

# 现网集群「基础设施服务」+「业务诉求」全量盘点
> 目的：为**新集群**定义"任务进去就能直接跑"的开箱即用基线。
> 横向 = 业务，纵向 = 基础设施提供的服务 / 业务特有诉求。
>
> 生成时间：2026-10-19　数据来源（全部只读取证，未触碰线上集群）：
> `/root/ascend-ci-deployment`（ArgoCD Application 908 个 / manifests / projects / other / monitoring / docs / git log）、
> 业务仓库 workflow（`gh api` 拉取的 `.github/workflows`、`.buildkite` 只读副本在 `/tmp/opencode/wf/`）、
> `/root/CLAUDE.md`、`/root/sh-001-*.md`、`/root/*model-downloader*.yaml`。
> 聚合脚本与原始结果：`/tmp/opencode/scan_apps.py`、`/tmp/opencode/apps_matrix.json`。

---

## 1. 盘点范围

### 1.1 集群（ArgoCD destination 名，共 22 个）
`ascend-hk-001-cluster`(HK 主) · `ascend-cn12-001-cluster`(CN12) · `openmerlin-guiyang-003/004/005/006/007-cluster` · `ascend-infra-guiyang-cluster-001`(gy-001) · `ascend-infra-guiyang-ipv6-cluster-002`(gy-002) · `ascend-infra-wlcb-cluster-001`(wlcb) · `openmerlin-sh-001-cluster` · `openmerlin-sh-002-cluster` · `ascend-aiframework`(hb-003) · `ascend-mind-third-ci`(hb-003-verl) · `suzhou-lab-shanghai1-cluster` · `infra-hk-opensourceway-ci-cluster`(hk-ci) · `infra-cn4-x86-common-cluster`(中心监控) · `hidevlab-k8s` · `ascend-karmada-test-cluster` · `ascend-ci-sglang-cluster-001`(sglang 华东2) · `ascend-triton-agent-ci` · `verl-suzhou`(`in-cluster`) · `dashboard`

### 1.2 业务（`projects/` 21 个 + `other/` 14 组）
| 业务 | ArgoCD 已部署集群数 | 集群 |
|---|---|---|
| vllm-project/vllm-ascend | 7 | cn12、hk-001、gy-001、gy-003、gy-005、gy-006、sh-001 |
| nv-action/vllm-benchmarks (other) | 7 | 同上（vllm-ascend 的 fork 镜像） |
| ascend-gha-runners/vllm-ascend (other) | 7 | cn12、hk、karmada-test、hidevlab、gy-005、gy-006、sh-002 |
| Ascend/pytorch | 4 | aiframework、cn12、gy-005、sh-002 |
| sgl-project/sglang | 4 | cn12、hk-001、gy-004、sh-002 |
| sgl-project/sgl-kernel-npu | 4 | cn12、hk-001、gy-004、sh-002 |
| volcengine/verl | 4 | cn12、hk-001、mind-third-ci、verl-suzhou(in-cluster) |
| vllm-project/vllm-omni | 4 | cn12、hk-001、gy-003、sh-001 |
| triton-lang/triton-ascend | 5 | cn12、hk-001、gy-001、gy-005、sh-002 |
| Ascend/sglang | 3 | cn12、hk-001、gy-004 |
| vllm-ascend/vllm-ascend-recipes | 3 | cn12、gy-001、sh-001 |
| sync-tools (other/ascend-gha-runners) | 5 | hk-001、mind-third、gy-003/004/005（跨集群盘同步） |
| tile-ai/tilelang | 1 | sh-002 |
| tile-ai/tilelang-mlir-ascend | 1 | cn12 |
| sgl-project/sglang-omni | 1 | hk-001 |
| alibaba/ROLL · areal-project/AReaL · Ascend/cann-container-image | 各 1 | cn12 |
| fla-org/flash-linear-attention · hiyouga/LLaMA-Factory · modelscope/ms-swift · pt-ecosystem(FLA-dev) · UsernameFull/transformers-ci · GanDing/Rlinf · volcengine/uni-agent · volcengine/verl-SpeCo · cosdt | 各 1 | hk-001 |
| volcengine/verl-omni · cosdt-ci-test · opensourceways | 各 1 | gy-001 |
| Ascend/ray-ascend · cosdt/vllm-ascend-integration-ci · xuedinge233/triton-ascend · vllm-ascend-kimi-k3(+) | 各 1 | gy-005 |
| agentic-develop-playground / opensourceways（hk-ci） | 1 | hk-ci |

---

## 2. 基础设施提供的服务（能力 → 入口 → 消费方契约 → 前置条件）

| # | 服务 | 入口（消费方看到的地址） | 业务必须做的配合动作（契约） | 集群侧前置条件 |
|---|---|---|---|---|
| S1 | **ARC**（gha-runner-scale-set-controller 0.14.2 / 0.13.0） | CR `AutoscalingRunnerSet`；metrics `:8080` | runner 目录 + `values.yaml` 的 `scaleSetLabels`（≥0.14 必须 2 标签）与 GitHub `runs-on` 严格一致 | GitHub App 凭据 Secret；controller 镜像架构匹配（0.14.201 仅 amd64，arm-only 集群改 0.14.2 多架构） |
| S2 | **NPU 设备插件 / 资源名** | `huawei.com/ascend-1980`(A3) / `huawei.com/ascend-310`(310P) / `Ascend910`(910B/a2b4) / `huawei.com/npu`(A5) / vNPU `ascend-1980-10c.3cpu.32g` | PodTemplate `resources.requests` 用**节点实际注册名**（曾写 `huawei.com/ascend-a5` 导致永久 Unschedulable） | 昇腾驱动 `/usr/local/Ascend/driver`、`/etc/ascend_install.info`、Ascend Docker Runtime、Device Plugin、ADR 与 DCMI 版本配套 |
| S3 | **npu-scheduler**（scheduler-plugins-new，runner 层） | `schedulerName: npu-scheduler`（变体 `-nofifo`、旧 `runner-pod-npu-scheduler`） | runner pod 带 `ascend-ci.com/required-npu-count / npu-resource-domain / npu-resource-model` 标签 | hostNetwork + arm64 + 私有 SWR 镜像 + pull secret；kube-system 权限 |
| S4 | **Volcano**（job 层 gang 调度）+ **Queue** | `schedulerName: volcano` + 注解 `scheduling.volcano.sh/queue-name` | job PodTemplate 双侧设置；`terminationGracePeriodSeconds: 90` | volcano 预装（cn12/hk/gy-006 为 CCE 预装；sh-001/002 由本仓库 chart 定制镜像，**需人工预载镜像到指定 master**）；Queue capability/deserved 需申请 |
| S5 | **LeaderWorkerSet** | CRD `leaderworkerset.x-k8s.io/v1`（当前仅 gy-003 部署） | 多机测试控制器用 `kubectl apply` 渲染 lws.yaml；需 ns 内 CR 创建权限 | LWS operator；镜像走 `registry.k8s.io`/daocloud 可达 |
| S6 | **Liqo**（跨集群 offload 1.2.0） | 虚拟节点 = provider clusterID；`NamespaceOffloading` CR | runner 注解 `liqo.io/api-server-support: remote`；手动容忍 `node.kubernetes.io/route-unreachable`；**两侧 PVC 同名**；hostPath share 名两侧同名 | peer 建立（`--networking-disabled`）、apiServer 地址可达（401=通）、ipam CIDR 手填、provider share-id 真实 |
| S7 | **Karpenter 弹性 CPU 池** | NodePool `demo.huawei.com/scenario=cpu-elastic:NoSchedule` | runner + job 双侧容忍 `cpu-elastic`、容忍 `karpenter.sh/unregistered:NoExecute(300s)`、软反亲和 weight=1、`karpenter.sh/do-not-disrupt` 注解 | 集群预装 Karpenter+CCENodeClass；**顺序：先 runner 容忍 → 再 NodePool 加污点** |
| S8 | **nginx-pypi-cache**（多生态拉取式缓存） | `http://cache-service.nginx-pypi-cache.svc.cluster.local`：80 `/pypi/simple` `/whl` `/ascend/repos`；8081 deb；8082 rust；8083 yum/openEuler；8084 goproxy；8085 crates(仅 -test/-v2) | pip/uv **必须** `--trusted-host`/`--allow-insecure-host`；apt/yum 用 sed 换源；`GOPROXY`/`RUSTUP_CACHE_URL`/`CARGO` 指到对应端口 | ns `nginx-pypi-cache`；SFS 1Ti（hostPath 集群须删 PVC）；容量 max_size 按集群核定；改 conf 需同步 `checksum/nginx-conf` + 漂移基线 |
| S9 | **squid**（SSL-Bump 出网代理 + registry 缓存 rpardini） | `http://squid-cache.squid.svc.cluster.local:3128`；`:3128` 内 registry-proxy；指标 9301/3901/9113 | 四套 `HTTP(S)_PROXY` 大小写 env；`NO_PROXY` 必绕 `.actions.githubusercontent.com,.blob.core.windows.net,api.github.com`（+`.svc.cluster.local`、按需 `gitcode.com`、`.buildkitd`、`.myhuaweicloud.com`）；挂 Secret `squid-ca-cert` + 6 个 CA env（`SSL_CERT_FILE/CURL_CA_BUNDLE/REQUESTS_CA_BUNDLE/GIT_SSL_CAINFO/PIP_CERT/NODE_EXTRA_CA_CERTS`）+ postStart 写系统信任库（ConfigMap `squid-ca-inject-script`） | secret-manager+Vault 有 `squid_ca_bundle_v3(_prod)_pem`；CA 需 AKI 补丁版（Py3.13+/conda 严格校验）；存储 SC 或 static PV；cache 独占节点 label/taint；`caNamespaces` 需 ns 已存在 |
| S10 | **git-cdn** | `http://git-cdn-service.git-cdn.svc.cluster.local:8000/` | runner postStart 写 `~/.gitconfig`：`[url "…:8000/"] insteadOf = https://github.com/` + `http.lowSpeedLimit/lowSpeedTime/postBuffer` | 单副本；amd64 且反亲和 NPU 节点；SFS RWX 200Gi（sh/verl 无 SFS 时 `persistence.enabled=false`）；pull secret |
| S11 | **smart-git-proxy**（bare mirror，hk-001/gy-005/gy-006） | `http://smart-git-proxy-service.smart-git-proxy.svc.cluster.local:8080/<host>/<owner>/<repo>` | insteadOf 到**带路径前缀** URL；`allowedUpstreams: github.com,gitcode.com` | 单副本（多副本会损坏 mirror）；SFS 500Gi RWX |
| S12 | **gh-proxy**（平台外置 GitHub 加速，非本仓库部署） | `https://gh-proxy.test.osinfra.cn/https://github.com/…` | workflow 里 `GITHUB_PROXY_URL`/`GIT_PROXY` 前缀下载 release/raw、wheel、zip | 集群出网可达 `*.test.osinfra.cn` |
| S12b | **`git-cache-github`**（遗留服务，仅 gy-001/gy-002/wlcb-001） | `http://git-cache-github.git-cache.svc.cluster.local:8080`（ns `git-cache`，**本仓库无 manifest**） | 拨测 `GH_PROXY_URL` 指向它；须与该集群 runner 实际在用的 git 代理一致，否则 `GitHubProxyUnreachable` 假告警 | 集群内已存在该服务（历史遗留）；新集群要么复刻，要么改 probe 目标 |
| S13 | **sfs-local-provisioner** | 节点 hostPath `/mnt/sfs-local/<share-name>` | runner/job 用 `hostPath` 挂 `/root/.cache`；**跨集群按 share 同名约定** | 特权 DS + `release: cceaddon-volcano` 豁免标签（否则 volcano gang 杀全 DS）；csi-sfsturbo SC + share-id |
| S14 | **Vault + secret-manager** | `https://vault.vault.svc:8200`（vault 仅 cn12/hk/hk-ci）；外部 `https://secret.osinfra.cn`（SecretDefinition） | `github-app-secret.yaml` / `github-token-secret.yaml` 指向 KV `secrets/data/ascend/ci`；buildkitd/argus/npu-exporter 走 vault-agent 注解 | Vault 需 unseal；AppRole Secret 预建；`secret-manager` CRD 先装；amd64 镜像（arm 集群要 patch） |
| S15 | **imagepullsecret-patch** | 产物：各 ns `huawei-swr-image-pull-secret-model-gy` | 所有私有镜像 PodTemplate 声明该 pull secret 名 | 源 Secret `image-pull-secret-src-model-gy` 手工预建；无 patcher 集群要另法补齐（hk/gy 系靠历史手工） |
| S16 | **buildkitd-server + dispatcher + KEDA** | `tcp://buildkitd-{arm64,amd64}-service.buildkitd:1234`；dispatcher `:8080` | job pod 注 vault-agent（role `buildkitd`）取 mTLS 证书到 `/home/user/.docker`；`buildctl --tlscacert/…`；`NO_PROXY` 含 `.buildkitd`；RUN 步骤经 squid | Vault `internal/data/ascend/buildkitd`；SA `buildkitd` 名固定（Vault role 按 SA 绑）；`devic.es/fuse`；节点 seccomp profile `infra-seccomp.json` |
| S17 | **generic-device-plugin** | 扩展资源 `devic.es/fuse`（cn12/hk/gy-006） | fuse-overlayfs 场景 requests `devic.es/fuse: 1` | 镜像走 ghcr 代理可达 |
| S18 | **监控（中心 CN4 + 各集群 agent）** | remote_write `http://113.44.182.82:9090/api/v1/write`；pushgateway LB `:9091`；拨测指标 push 入中心 | 无（但告警 runbook 依赖 squid/git-cdn/NTP/DNS 就位） | node-exporter 静态 IP 列表需人工更新；出口 IP 需在中心白名单内，否则集群内 pushgateway-local 中转（**版本必须 v1.10.x**）；拨测 CronJob 全家桶 |
| S19 | **NPU exporter**（npu-exporter-ascend，hostPort 9101） | 指标 → 中心 | — | 节点驱动/npu-smi；Ascend950DT 需额外 `liburma.so.0`（整挂 `/usr/lib64` 会污染 glibc → CrashLoop） |
| S20 | **zombie-runner-cleanup**（CronJob 每 15min，10 集群） | — | — | ARC CRD + arc-systems SA；镜像自带 kubectl；**必须 `--wait=false`** |
| S21 | **model-cache-cleanup**（周二 19:00，7 集群，非 GitOps） | — | 权重 atime 语义：任意文件被读过即整仓续命 | 静态 PV 镜像 SFS export；同 share 只在一侧清理 |
| S22 | **KEDA / argus / volcano-queue / harbor 等**（gy-006 集中） | argus LB、harbor SC 等 | 按需用 | 各自 chart 依赖 |

---

## 3. 集群 × 基础设施服务覆盖（据 ArgoCD Application 实测统计）

| 服务（集群数） | 覆盖集群 |
|---|---|
| **squid-rpardini** (12) | hk-001、cn12、gy-001、gy-002、gy-003、gy-004、gy-005、aiframework、mind-third、sh-001、sh-002、wlcb（+ gy-006 helm 直部，app 已注释） |
| **nginx-pypi-cache** (14) | -new：hk-001、aiframework、mind-third、hk-ci、gy-001、gy-003、gy-004、gy-005、sh-001、sh-002、suzhou、wlcb；-v2：cn12；-test(canonical)：gy-006 |
| **git-cdn** (14) | hk-001、cn12、aiframework、mind-third、gy-001、gy-003、gy-004、gy-005、gy-006、sh-001、sh-002、wlcb、hidevlab、verl-suzhou(in-cluster)；+ gy-006 第二实例 `git-cdn-gitcode` |
| **smart-git-proxy** (3) | hk-001、gy-005、gy-006 |
| **npu-scheduler(scheduler-plugins-new)** (13) | hk-001、cn12、aiframework、mind-third、gy-001、gy-003、gy-004、gy-005、sh-001、suzhou、hidevlab、verl-suzhou、（gy-006 用旧版+test） |
| **volcano** | 本仓库 chart 仅 sh-001、sh-002；cn12/hk-001/gy-006 为集群预装；Queue app：cn12、hk-001、gy-006 |
| **liqo** (10) | consumer：cn12、gy-006、hk-001；provider：aiframework、mind-third、gy-001、gy-004、gy-005、wlcb、suzhou、cn12 |
| **Karpenter cluster-autoscaling** (5) | gy-003、gy-004、gy-005、gy-006、hk-001（gy-005/006 已带污点，hk-001 runner 就绪待合，gy-003/004 旧模式） |
| **sfs-local-provisioner** (9) | hk-001、cn12、aiframework、mind-third、gy-001、gy-003、gy-004、gy-005、gy-006 |
| **vault** (3) | cn12、hk-001、hk-ci |
| **secret-manager** (8) | cn12、gy-001、gy-002、wlcb、mind-third、hk-ci、gy-007、suzhou |
| **imagepullsecret-patch** (8) | cn12、aiframework、mind-third、hk-ci、gy-007、sh-001、sh-002、suzhou |
| **buildkitd-server** | cn12、hk-001、gy-006、sglang 华东2（dispatcher+KEDA 仅 gy-006 闭环） |
| **generic-device-plugin** (3) | cn12、hk-001、gy-006 |
| **arc-controller** | 0.14.2×12 集群；0.13.0×4（karmada-test、hidevlab、verl-suzhou、hk-ci） |
| **zombie-runner-cleanup** (10) | hk-001、cn12、aiframework、mind-third、gy-001、gy-003、gy-004、gy-005、gy-006、sh-001 |
| **npu-exporter-ascend** (12) | hk-001、cn12、aiframework、mind-third、gy-001、gy-003、gy-004、gy-005、gy-006、sh-001、sh-002、wlcb |
| **监控 overlay** (16) | 上表 config-for-* 全量；中心 = infra-cn4-x86-common-cluster |
| **LWS** | 仅 gy-003 |
> 注：`model-cache-cleanup`、`nginx-conf-drift` **没有任何 ArgoCD Application**（脚本手工部署）→ 新集群容易漏装。

---

### 3.1 三个"云下/边缘"集群专章：gy-001 · gy-002 · wlcb-001

> 这三处在主矩阵里容易被忽略，但它们各自代表一种**新集群会遇到的形态**：gy-001 = "老集群既要跑 CI 又当 Provider"；gy-002 = "纯基础设施（无 runner）"；wlcb-001 = "纯 Provider（runner 建在别处，pod 落这里）"。

#### gy-001（`ascend-infra-guiyang-cluster-001`）— 28 个 Application
| 维度 | 现状 |
|---|---|
| 基础设施 | ARC 0.14.2、npu-scheduler(scheduler-plugins-new)、squid（2 副本，钉 `172.16.0.37`，`cache=true:NoSchedule`，cacheDisk 200G/maxObject 8G）、git-cdn（同节点，`sfsturbo-subpath-sc` 200Gi RWX）、nginx-pypi-cache-new（镜像 patch 为 `modelfoundry/nginx_pypi_cache:latest`）、**sfs-local-provisioner**、liqo-provider（clusterID `gy001`，apiServer `101.245.109.198:5443`，podCIDR `10.0.0.0/16`/svc `10.247.0.0/16`，reservedSubnets `172.16.0.0/24`，`networking.enabled=false`，控制面同样钉 37 节点+cache 容忍）、secret-manager、npu-exporter-ascend、prometheus-agent+KSM、zombie-runner-cleanup |
| 缺失（相对 P0） | vault、imagepullsecret-patch（`huawei-swr-image-pull-secret-model-gy` 需已手工存在）、volcano（job 层走集群预装/无）、buildkitd、KEDA、LWS、Karpenter |
| 在跑的 business | vllm-ascend `a2b1-{1,2,4,8}`、nv-action `a2b1`、triton-ascend `a2b1`、vllm-ascend-recipes `a2b4`、verl-omni `a2b4`、cosdt-ci-test `a2-{1,2,4,8}`、opensourceways `a2-{1,2,4,8}`、ascend-gha-runners `amd64-cpu-2-gy001` + hk 侧 `a2-1-gy001`（offload 进来） |
| 业务诉求细节 | runner 标签 `ascend-ci.com/npu-resource-model: ascend-1980`（A2B1 也报 1980 资源名）+ `schedulerName: npu-scheduler`；job nodeAffinity 用 **`node.kubernetes.io/npu.chip.name`** 选芯片；squid 四套 proxy env + CA 六件套 + `NO_PROXY=0.0.0.0,localhost,127.0.0.1,.buildkitd,.svc.cluster.local,.cluster.local,.actions.githubusercontent.com,.blob.core.windows.net,api.github.com`；`PIP_CACHE_DIR=/tmp/pip-cache`；`ASCEND_WORK_PATH=/root/.cache/log/plog/<org>/<repo>/$(HOSTNAME)`；hostPath **`/mnt/sfs-local/vllm-ascend-az5`**（与 gy-005 同 share 名 → Liqo 跨集群同名约定的活样本）；`obs-cache-secret`（OBS AK/SK）；listener 钉 cache 节点（cosdt-ci-test、opensourceways：`hostname=172.16.0.37` + cache 容忍） |
| ⚠️ 集群内不一致 | **同一集群里 git 加速有两种消费方式**：vllm-ascend/triton-ascend 用集群内 `git-cdn-service.git-cdn.svc:8000`，cosdt-ci-test/opensourceways 直接用 `https://gh-proxy.test.osinfra.cn/https://github.com/`；另外拨测 `GH_PROXY_URL` 指向**仓库外手工部署的老服务** `git-cache-github.git-cache.svc.cluster.local:8080`（ns `git-cache`，本仓库无 manifest） |
| ⚠️ 历史反复 | "secret-manager 通过 ArgoCD inline patch 容忍 cache 污点"（gy-001/gy-002/wlcb）曾提交后被 **revert**（`fc11b9de`）→ 单 cache 节点集群的 operator 落位问题需现场确认 |

#### gy-002（`ascend-infra-guiyang-ipv6-cluster-002`，IPv6 集群）— 仅 3 个 Application
- 定位：**纯基础设施供给方，不承载任何 runner/业务**（主矩阵所有业务列对它都是 `—`）
- 内容：squid（2 副本，钉 `10.0.1.220`，amd64，`label cache=true` + `taint cache`；依赖 ns 内已存在的 `huawei-swr-image-pull-secret-model-gy`）、`monitoring/config-for-guiyang-002`（prometheus-agent，含 mtail/registry-nginx 抓取顺序修正 `aaafdf4e`/`65ce043c`）、kube-state-metrics；另有根级 `secret-manager-guiyang-002` app
- 拨测同样指向 `git-cache-github.git-cache.svc:8080`（曾因此误报 `GitHubProxyUnreachable`，修于 `77bdb52b`/`2fa7f351`）
- 对"新集群"的启示：**一个集群可以只对外提供 egress 代理 + 观测**，此时 P0 里的 ARC/NPU/存储整段都可以不打；但 squid 的 cache 独占节点 + pull secret + 拨测目标这三件事仍必须做对

#### wlcb-001（`ascend-infra-wlcb-cluster-001`，乌兰察布）— 10 个 Application，纯 Liqo Provider
- 定位：**自己不建 runner**。runner scale set 在 hk-001（Consumer）建一份，pod offload 进来（`linux-aarch64-a2-1-wlcb001`、a2b4 池；commit `381da996` 统一了 hk-001/gy001/wlcb001 三处 vllm-ascend PVC 名并把 a2b4 钉到 gy001）
- 节点形态：arm64 **910B4（A2B4）** 为主 + 集群内**唯一 x86 节点 `192.168.1.191`**（`node.kubernetes.io/instance-type=c7.16xlarge.2`，带 `cache=true:NoSchedule`）→ 该节点同时承载 Liqo 控制面 + git-cdn + 既有 git-cache-http-server，所以 git-cdn 资源被下调到 4C/8Gi
- 基础设施：liqo-provider（clusterID `wlcb001`，apiServer `1.92.221.43:5443`，reservedSubnets `192.168.1.0/24`，`defaultNodeResources huawei.com/ascend-1980: "56"` = 8 节点×8 卡 − 留 1 台）、squid（钉 `192.168.1.49`，该节点只有 `cache=true` **label 无污点**；`caNamespaces` = squid/op-plugin/mindspeed-mm/mindspeed-bridge，说明集群内还有非 CI 的 mindspeed 业务在用 CA）、git-cdn（upstream gh-proxy：国内集群不直连 github）、nginx-pypi-cache-new（image patch + `cache` toleration 内联）、scheduler-plugins-new、npu-exporter-ascend、secret-manager、monitoring+KSM、provider-side PVC/RBAC 三套（vllm-ascend / nv-action / ascend-gha-runners-hk-001）
- 缺失：ARC controller、volcano、sfs-local-provisioner、zombie-runner-cleanup、vault、imagepullsecret-patch、Karpenter、LWS、buildkitd
- ⚠️ 反复：git-cdn 曾被删（#1647）后又恢复（`5dec7fce`，issue #2178"打通云上所有 A2 资源"）；nginx-conf-drift 哨兵在 wlcb 需要 toleration（`ci-probe` 镜像无 arm64 变体，`4d7db947`/`ca8d34eb`）
- 对"新集群"的启示：**Provider 形态的最小集** = Liqo + 芯片对应的 npu-scheduler + 出网三件套（squid/nginx/git-cdn）+ provider-side 同名 PVC/RBAC + exporter；ARC/vault/cleanup 都不必装

## 4. 主矩阵：纵向 = 服务与诉求，横向 = 业务

图例：`●●` 硬依赖（缺了直接跑不起来，CI 里硬编码）｜`●` 需要（有兜底/仅变慢）｜`▲` 该业务特有｜`—` 不适用｜`?` 待核（未取到直接证据）

### 表 A：主力推理/框架业务（列 = vllm-ascend、vllm-omni、recipes、sglang、Ascend/sglang、sgl-kernel-npu、sglang-omni、triton-ascend）

| 服务 / 诉求 | vllm-ascend | vllm-omni | vllm-ascend-recipes | sgl-project/sglang | Ascend/sglang | sgl-kernel-npu | sglang-omni | triton-ascend |
|---|---|---|---|---|---|---|---|---|
| **S1 ARC runner** | ●● | ▲ Buildkite agent-stack（非 ARC） | ●● | ●● | ●● | ●●（新旧两代栈） | ●● | ●● |
| **S2 NPU 资源名（含 A3/A5/310P/910B/800T/800I）** | ●● 全谱 | ●● a3/a2b3/310p/a5 | ●● a2b4/a5/800i | ●● a3/800t/a5 | ●● a3/a2b3/800t | ●● a3/800i/800t/a5/旧 npu-* | ●● a2 | ●● a3/800i/a5 |
| **S2b vNPU 切片 `ascend-1980-10c/5c`** | ▲ 唯一在用（a2b3-v-half/quarter） | — | — | — | — | — | — | — |
| **S3 npu-scheduler（runner 层）** | ●● | ●● | ●● | ●● | ●● | ●●（含旧名 runner-pod-npu-scheduler） | ●● | ●● |
| **S4 volcano + queue** | ●● `vllm-queue`/`vllm-test-queue` | ●● Buildkite queue + volcano | ●（无 queue 名） | ●● `sglang-queue`/`sglang-npu-cn12-queue` | ●● `sglang-queue` | ●● `sgl-kernel-npu-cn12-queue` | ●● `sglang-queue` | ●● |
| **S5 LWS（多机）** | ●● nightly 多机 `kubectl apply lws.yaml` | ● | ●● `leaderworkerset` | ●● PD 分离 LWS | ● | ● | ● | — |
| **S6 Liqo offload** | ●●（gy-001/wlcb） | ●●（cn12 offload ns） | — | ●（gy-004/aiframework/mind） | ●（gy-004） | ● | — | ● |
| **S7 Karpenter 弹性 CPU** | ●（cpu runner 全量容忍） | ● | — | ● | — | ● | ● | ●●（buildkit CPU 池） |
| **S8 nginx-pypi-cache pip** | ●● `PIP/UV_INDEX_URL=cache-service…/pypi/simple` | ●● 同 | ●● 同 | ●● 同 + 三级回退(pypi.org/清华) | ●● 同 | ●●（56 处引用） | ● 未见 | ●● |
| **S8b cache `/whl`（PyTorch）** | ●● `/whl/cpu` | ● | ● | ●● | ● | ● | — | ●（download.pytorch 兜底） |
| **S8c cache `/ascend/repos`（torch-npu/大 wheel）** | ●● | ● | ● | ●● | ●● | ●● | — | ●●（extra-index） |
| **S8d cache 8081 deb/apt** | ●● sed 换源 | ● | ● | ●● | ●● | ●● | — | ●（apt 装包，是否走缓存未直接取证） |
| **S8e cache 8082 rust** | — | — | — | ●● `RUSTUP_CACHE_URL` | ●● `:8082` | ● | — | — |
| **S8f cache 8083 yum(openEuler)** | ● | ● | — | ? | ? | ● | — | ? |
| **S8g cache 8084 goproxy** | ● | — | — | ● | — | ● | — | — |
| **S8h cache 8085 crates**（能力仅在 -test/-v2 布局） | — | — | — | — | — | — | — | — |
| **S9 squid 代理 + CA 注入** | ●●（全套 6 CA env + postStart 写信任库） | ● | ● | ●● | ● | ● | ● | ●●（buildkit 模板） |
| **S10 git-cdn insteadOf** | ●● | ●● | ● | ●● | ●● | ●● | ● | ●● |
| **S11 smart-git-proxy** | ●（hk/gy-005/006） | — | — | — | — | — | — | — |
| **S12 gh-proxy.test.osinfra.cn** | ●●（FLA NPU wheel） | ● | ● | ●●（triton/sgl-kernel/custom-ops zip） | ●● | ●●（28 处） | ● | ● |
| **S13 sfs-local `/mnt/sfs-local/<share>`** | ●● | ●● | ● | ●● | ●● | ●● | ●● | ●● |
| **S14 Vault/SecretDefinition（GitHub 凭据）** | ●● token | ●● buildkite-token-secret | ●● | ●● | ●● | ●● | ●● | ●● |
| **S15 SWR 镜像 + pull secret** | ●● 双 secret(gy+cn12) | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **S16 buildkitd 远程构建** | ●●（hk cpu-16/32 + vault） | — | — | ● | — | ● | — | ●●（cpu-4-buildkit 专用 runner） |
| **S17 fuse 设备（`devic.es/fuse`）** | ● | — | — | — | — | — | — | ●● |
| **S18 监控/拨测** | ● | ● | ● | ● | ● | ● | ● | ● |
| **S19 npu-exporter** | ● | ● | ● | ● | ● | ● | ● | ● |
| **S20/S21 runner 清理 / 模型缓存清理** | ●● | ● | ● | ●● | ● | ●● | ● | ● |
| **S22 Harbor/镜像仓库推送（SWR/quay/docker.io）** | ●● SWR+quay | ● | ● | ●● SWR+docker.io | ●● | ●● | ● | ●● SWR+quay |
| **B1 egress 出公网（GitHub/PyTorch/pypi）** | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **B2 NGFW 域名白名单（云下）** | ●（sh-001/sz-lab） | ● | ● | ● | — | — | — | — |
| **B3 apiserver ELB 白名单 + certSANs** | ●●（nightly 要 kubectl） | ●● | ●● | ●● | — | — | — | — |
| **B4 中心监控出口白名单 / pushgateway 中转** | ● | ● | ● | ● | ● | ● | ● | ● |
| **B5 自定义 DNS（`dnsPolicy: None` / `/etc/resolv.conf` 覆写）** | ▲ 910b(sz-lab) 10.96.0.10/10.247.3.10 | ▲ | — | ●（ConfigMap 取 peer IP） | — | — | — | — |
| **C1 共享缓存盘 `/root/.cache`（SFS/RWX 或 hostPath）** | ●● 多盘（az5、hk001、nv-action 大盘） | ●● az5 | ●● | ●● | ●● pkSING 盘 | ●● | ●● | ●● |
| **C2 模型权重盘（`/mnt/weight`、`/mnt/share`、`/data`）** | ●● sh-001 `/mnt/weight` | ●● `/mnt/share` | ●● `/mnt/weight` | ● | ● | ● | ● | ● |
| **C3 公共大盘被多业务共用** | ●● `nv-action-vllm-benchmarks-v2`（LWS 默认 PVC） | ● | — | ● | ● | — | — | ● |
| **C4 只读子目录挂载试点（huggingface/modelscope）** | — | ● | — | — | — | — | — | — |
| **C6 NFS `fcntl.flock` 不互斥（并发写缓存风险）** | ● | ● | — | ●●（ms-swift 风格 flock 不适用） | — | — | — | ●●（ccache） |
| **D1 零卡下载 runner（`*-0`：a2b3-0/a3-800t-0/a5-0）** | ●● `labeled_download_model_dataset.yaml` | ● | ● | ●●（多机控制器 `a3-800t-0`） | ●● | ●●（`linux-amd64-cpu-0`） | — | — |
| **D2 HF/ModelScope 下载通道（`HF_ENDPOINT`、`modelscope download`）** | ●● ModelScope | ●● 离线 | ●● | ●● `SGLANG_USE_MODELSCOPE`+`hf-mirror.com` | ●● | ● | — | ● |
| **D3 离线跑测（`HF_HUB_OFFLINE=1`、`~/models` 软链）** | ●● | ●● 强制 | ●● | ● | ●● | ● | — | — |
| **D4 清单驱动（`misc/model_dataset_list.json` + PR label）** | ●● | — | — | ●（performance 用例路径清单） | ● | — | — | — |
| **D5 大模型下载专用 pod（手工长跑，非 workflow）** | ▲ ns `vllm-project`：`tc tbf` 限速 200mbit + privileged + `HF_ENDPOINT=hf-mirror.com`（云下）/`huggingface.co`（HK） | ▲ 同 | — | — | — | — | — | — |
| **D6 sync-tools 跨集群盘同步 runner** | ●● | ● | — | ●● | ●● | ● | — | ● |
| **D7 OBS/S3 远端缓存（`RUNS_ON_S3_BUCKET_CACHE=ascend-ci-cache-hk`）** | ●● | — | — | — | — | — | — | ●（obsutil 上传/下载 wheel） |
| **D8 大文件二进制依赖（custom-ops/ops-transformer/sgl-kernel-npu zip、triton wheel、Bisheng 编译器）** | ●● | ● | ● | ●● | ●● | ●● | — | ●●（OBS + sha256 + 断点续传） |
| **D9 wheel/apt 装包（`sudo apt-get install`）** | ●● gh、git、jq | ● | ● | ●● 依赖脚本 apt update | ●● | ●● | ● | ●● clang |
| **E1 夜间时间窗污点 `dedicated=night` + CI 定时摘污点** | ●● 唯一（a2/a3 nightly，`kubectl taint nodes $A2/A3_TAINT_NODES dedicated-`） | — | — | ● 容忍（无摘污点步骤） | ● | ● | — | — |
| **E2 机型池污点 `dedicated=752t`** | ●● | — | — | ●● | — | ● | — | — |
| **E3 整机池污点 `single-node=true`** | — | — | — | ● | ●● | — | — | — |
| **E4 缓存节点独占 `cache=true`（squid/nginx/git-cdn 钉节点）** | 平台侧 | 平台侧 | 平台侧 | 平台侧 | 平台侧 | 平台侧 | 平台侧 | 平台侧 |
| **E5 弹性污点 `cpu-elastic` + 软反亲和** | ●● | ● | — | ● | — | ● | ● | ●● |
| **E6 节点钉选（listener/runner 钉 hostname）** | ▲ sh-001 `admin123` | — | — | — | — | — | — | — |
| **E7 Queue deserved/capability 预留卡数** | ●● vllm-queue 40 | ● | — | ●● sglang 104/无限制 | ●● | ●● 80 | ● | ● |
| **E8 维护窗口门禁（`NIGHTLY_COMMAND_BLOCK_WINDOW` / nginx rollout gate）** | ●● | — | — | ● | ● | ● | — | ● |
| **F1 ns Role（pods/exec、jobs、secrets）** | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **F2 cluster 级 nodes patch 权限（打/摘污点 kubeconfig）** | ●● `KUBECONFIG_B64`/`KUBECONFIG_HK_001_INTERNAL_B64` | ● | ● | ●●（PD 编排） | ● | ● | — | — |
| **F3 hostNetwork / privileged / `--device /dev/davinci*`** | ●（多机 hostIP） | ●● `hostNetwork: true`×4 | ● | ●● PD `privileged`+hostNetwork | ● | ● | — | ●（docker `--network host`） |
| **F5 GitHub 仓库 secrets/vars** | ●● 20+ 项 | ● | ● | ●● | ●● | ●● | ● | ●● |
| **F8 NTP/时钟** | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **F9 listener(amd64)/runner(arm64) 架构分离** | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **F10 日志归档 `ASCEND_WORK_PATH=/root/.cache/log/plog/<org>/<repo>`** | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |

### 表 B：其余业务（列 = tilelang、verl、Ascend/pytorch、ms-swift、LLaMA-Factory、FLA、ROLL、AReaL）

| 服务 / 诉求 | tile-ai/tilelang | volcengine/verl | Ascend/pytorch | modelscope/ms-swift | hiyouga/LLaMA-Factory | fla-org/FLA | alibaba/ROLL | areal/AReaL |
|---|---|---|---|---|---|---|---|---|
| **S1 ARC** | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●●（800i chart 缺 scaleSetLabels，偏离规范） |
| **S2 NPU 资源名** | ●● `huawei.com/npu` | ●● `Ascend910`/`ascend-1980` | ●● a3/800i/a5 | ●● a2 | ●● a2 | ●● a2 | ●● a3/800i | ●● a3/800i |
| **S3/S4 调度器 + queue** | ●● volcano + `▲ huawei.com/schedule_policy: chip4-node8` | ●● `verl-queue` | ●● | ●● volcano | ●● volcano | ●● volcano | ●● | ●●（无 queue 名） |
| **S5 LWS / 多机** | — | ▲ RayJob 服务 `rayjob-submitter.ci-system.svc` | — | — | — | — | — | ●（Ray 类） |
| **S6 Liqo** | — | ●● `verl-project-liqo` 覆盖 3 集群 | ●（aiframework/mind） | — | — | — | ● | ● |
| **S7 Karpenter** | — | — | ●● cpu-24 弹性专测 | — | — | ● | ● | ● |
| **S8 nginx-pypi-cache** | — ▲ 反例：走宿主 `runner.tool_cache`，明确不用远端 cache | ●● 硬编码无回退 | ●● | ●● + `:8081` | ●● + `:8081` | — ▲ 用 `triton-ascend.osinfra.cn/pypi/simple` | — ▲ 用公网 `repo.huaweicloud.com` | ●（git-cdn） |
| **S9 squid + CA** | — | ▲ 裸 IP 代理 `100.68.174.87:3128`（GPU 线） | ● | ● | ● | ● | — | — |
| **S10/S12 git 加速** | ●● git-cdn | ●● git-cdn + gitcode 直连 | ●● | ● | ● | ● | — 裸 github | ●● |
| **S13/S14/S15** | ●● NFS 静态 PV + pull secret | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **S16 buildkitd** | — | — | — | — | — | — | — | — |
| **C1/C2 存储** | ●● 自建 NFS `/home/share/ascend-ci-share-tilelang` | ●● hk001 整盘 + `▲ /nfs/verl_ci` + `▲ 192.168.9.104:32303` 自建 pypi | ●● az5/自建 NFS(sh-002) | ●● | ●● 整盘 hk001-v1 | ●● | ●● | ●● 整盘 shared-v3 |
| **C5 只读缓存试点** | — | ▲ `a2-test-8`/`a3-800i-test-8` 只挂 huggingface/modelscope readOnly | — | — | — | — | — | — |
| **D2/D3 模型与数据集** | — | ●● `ln -s /root/.cache/modelscope/hub/models ~/models` + 数据集断言 + `hf-mirror` + `HF_TRANSFER=0` | ●● OBS 通道 | ●● `MODELSCOPE_CACHE` | ●● `HF_ENDPOINT=hf-mirror` + `HF_TOKEN` | ●● hf-mirror | ●● hf-mirror | ●● |
| **D7 OBS 制品/基线** | — | ● 基线走 `raw.githubusercontent.com` | ●● `obs://pytorch-ci-cache`（唯一产物通道） | — | — | — | ● actions-cache | — |
| **D10 install-docker-cli 预热** | — | — | — | — | — | — | — | — |
| **E1/E6 时间窗/钉节点** | — | ▲ suzhou `hostNetwork` + `GLOO_SOCKET_IFNAME` | ●（弹性池） | — | — | — | — | — |
| **E8 维护窗口** | — | — | — | — | — | — | `PREPARE_JOB_TIMEOUT=43200` | — |
| **F3 privileged / 设备直通** | ● driver 路径 env | ●● hostNetwork | ●● `--device /dev/davinci0..7` + `--network host` + label=disable | ●● `--privileged` + 4 卡直通 + `/usr/local/Ascend` 只读挂 | ● | ● `--shm-size 16g` | ● | ● |
| **F4 编译缓存/OOM 约束** | ●● ccache 预装 + `-M 20G`（runner 必须自带 ccache） | ● | ●● 宿主 `/data/torchnpu-ccache` | — | — | — | — | — |
| **F5 secrets** | ● | ●● | ●●（OBS AK/SK、SWR） | ●● | ●● | ●● | ●● | ●● |
| **F10 plog 约定** | ●● | ●● | ●● `ASCEND_PROCESS_LOG_PATH` | ● | ● | ● | ● | ● |

### 表 C：仅个别业务特有的"例外列"（新集群要按需求决定是否提供）
| 特例诉求 | 提出方 | 集群侧必须做的事 |
|---|---|---|
| 定时打/摘污点做**夜间整机独占** | vllm-ascend（+ nv-action fork） | 夜间池预打 `dedicated=night:NoSchedule`；runner+job 双侧 toleration；给 `npu-scheduler-nofifo`；提供内网 kubeconfig secret + `nodes` patch 权限；配 `vars.A2_TAINT_NODES/A3_TAINT_NODES` |
| **OBS/S3 作 ARC 远端缓存** | vllm-ascend、ascend-gha-runners | `obs-cache-secret`（AK/SK）+ `RUNS_ON_S3_BUCKET_*` 变量 + 出网放行 `obs.ap-southeast-1` |
| **离线模型（禁止联网拉权重）** | vllm-omni、verl、sglang | 共享盘预置权重（`modelscope/hub/models`、`datasets/`）+ `HF_HUB_OFFLINE=1`、`TORCH_HOME`、`LD_PRELOAD=jemalloc` |
| **RayJob 提交服务** | volcengine/verl | 集群需已有 `rayjob-submitter.ci-system.svc` + RayCluster 模板 + 16 卡 worker 组 + 业务自带 `/etc/resolv.conf` 覆写 |
| **自建 pypi NodePort + hostNetwork** | verl（suzhou） | 集群内 `192.168.9.104:32303` + trusted-host；gloo 需绑数据网卡 |
| **自建 NFS 静态 PV（无 SFS）** | sh-002 系（pytorch/sglang/tilelang/triton） | `179.60.12.2:/home/share/*` 预导出 + `storageClassName: ""` 静态 PV + `volumeName` 绑定 |
| **vNPU 切片共享卡** | vllm-ascend（+ ascend-gha-runners gy-006） | device plugin 开 `ascend-1980-10c.3cpu.32g`/`-5c` 资源 |
| **按用途给节点打污点做长期独占（非 nightly）** | 模型下载 / 大缓存 | hk-190 下载 pod 容忍 `node.usage.notes=single_node_download_large_model:NoSchedule`；sh-001 下载 pod 容忍 `unschedulable`（cordon 态）并 `nodeName` 直钉 lab-worker-03；证据 `/root/hk-model-downloader-190.yaml`、`/root/sh001-model-downloader.yaml`、`/root/gy003-model-downloader.yaml` |
| **DinD privileged sidecar** | agentic-develop-playground、opensourceways | `docker:27-dind` + `/var/lib/docker` + `DOCKER_TLS_CERTDIR`，节点需 docker/containerd 权限 |
| **legacy 栈 `imagePullPolicy: Never`** | Ascend/a2b4、sgl-kernel-npu、cosdt-integration-ci | 节点必须**预缓存 runner/actions-runner 镜像**（装机模板带镜像 tar） |
| **Buildkite agent-stack**（非 ARC） | vllm-project/vllm-omni | Buildkite agent token secret + queue + resource-class；ns/RBAC 与 vllm-ascend 拆分（防 sync-prune 互抢） |
| **Karmada PropagationPolicy** | ascend-gha-runners（karmada-test） | Karmada 控制面 + ELB + 成员集群注册 |
| **拨测经集群内 pushgateway 中转** | sh-001、sh-002 | 出口被 NGFW/白名单掐时部署 `pushgateway-local`（v1.10.x）+ honor_labels 抓取 |
| **git-cdn PAT 鉴权** | ascend-gha-runners/add-node-check | secret `git-cdn-pat`（`x-access-token`） |
| **只读缓存 runner（防污染大盘）** | verl、AReaL | `*-test-*` runner 只挂 `huggingface/`、`modelscope/` 子目录 `readOnly` |

---

## 5. 新集群"开箱即用"最小集（按优先级）

**P0｜不做就一个任务都跑不起来**
1. 昇腾驱动 + Ascend Docker Runtime + Device Plugin（版本配套）+ NPU 资源名与业务 `requests` 对齐
2. `npu-scheduler`（runner 层）+ `volcano` + 队列（含 queue 注解契约）+ LWS（多机业务）
3. ARC controller（架构匹配）+ 每业务 ns 的 PVC/RBAC/SA + GitHub App 凭据（Vault KV `secrets/data/ascend/ci`）
4. 共享存储：SFS Turbo（或自建 NFS）+ `sfs-local-provisioner` 的 `/mnt/sfs-local/<share>` 同名约定 + `/root/.cache` + 权重盘（`/mnt/weight` 或 PVC）
5. 镜像通道：SWR + `huawei-swr-image-pull-secret-model-gy`（imagepullsecret-patch 或手工）+ containerd 镜像加速（certs.d/hosts.toml，改后重启）+ 必要镜像预缓存
6. egress：squid（含 CA 注入契约、NO_PROXY 绕 GHA 控制面）+ nginx-pypi-cache（80/8081/8083/8084 + `--trusted-host`）+ git-cdn insteadOf + `gh-proxy` 可达
7. 时钟（chrony/NTP，NTP 被封则 HTTP-Date 兜底）+ CoreDNS forward 可达（DNS 顺序）+ apiserver 入口与 certSANs/白名单

**P1｜缺了业务能跑但会红/会慢**
8. Karpenter `cpu-elastic` 污点方案（runner 双侧容忍 + 软反亲和 + do-not-disrupt）
9. Liqo（若需要跨集群卡池）+ 双侧同名 PVC/hostPath 约定
10. Vault/secret-manager（若走 SecretDefinition）、buildkitd + dispatcher + KEDA + fuse 设备
11. 模型/数据集下载通道：`*-0` 零卡 runner + modelscope/hf-mirror + `model_dataset_list.json` 驱动的预置 + 可选 `tc` 限速 downloader pod
12. OBS 凭据与远端缓存（`RUNS_ON_S3_BUCKET_CACHE`）、制品基线桶
13. 监控（prometheus-agent → 中心 + 拨测 CronJob + npu-exporter + node-exporter + KSM）、zombie-runner-cleanup、model-cache-cleanup、nginx-conf-drift
14. 时间窗污点协作机制（`dedicated=night`/`752t`/`single-node` + CI 摘污点所需 cluster 权限 + `vars.*_TAINT_NODES`）

**P2｜特定业务才需要**
15. vNPU 切片、Karmada、Harbor/Argus/Milvus（gy-006 生态）、Ingress+Vault TLS（dashboard 类）、DinD 特权 runner、只读缓存试点 runner、自建 pypi NodePort

---

## 6. 待人工核验（需要访问线上集群，本次未做）
建议由有权限的人执行以下**只读**命令补齐（我未运行任何 kubectl）：
1. `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints` —— 各集群现存污点全集（`dedicated`/`cache`/`single-node`/`instance`/`node.usage.notes`/`cpu-elastic`），确认新集群需要复刻哪些
2. `kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable}{"\n"}{end}` —— NPU 资源名与可分配量（对齐业务 `requests`）
3. `kubectl get sc,pvc -A | grep -E 'sfsturbo|csi-disk|nfs'` + 节点上 `mount | grep sfs` —— `/mnt/sfs-local/<share>` 实际存在清单（Liqo 与只读缓存 runner 依赖同名）
4. `kubectl get svc,ep -n squid -n nginx-pypi-cache -n git-cdn -n buildkitd` —— 服务真实可达地址与端口（矩阵 S8~S11 的入口列）
5. `kubectl get networkpolicy -A`、`kubectl get cm coredns -n kube-system -o yaml` —— 确认"NetworkPolicy 未启用、入站靠安全组"的现状是否延续
6. `kubectl get cronjob -A` —— 校验 `model-cache-cleanup`/`nginx-conf-drift` 是否已在各集群存在（仓库内无 ArgoCD app，极易漏装）
7. 中心 CN4 白名单：确认新集群公网出口 IP 是否已放行 `113.44.182.82:9090/9091`，否则要装 pushgateway-local
8. GitHub 仓库侧变量：`vars.A2_TAINT_NODES`/`A3_TAINT_NODES`、`vars.NIGHTLY_COMMAND_BLOCK_WINDOW`、secrets `KUBECONFIG_*_B64`/`OBS_*`/`HW_OBS_*`/`SWR_*`/`SYNC_TOOLS_TOKEN`/`QUAY_*`/`PAT_TOKEN` 是否需要为新集群新建一份
9. gy-001/gy-002/wlcb-001：`kubectl -n git-cache get deploy,svc`（遗留 `git-cache-github` 是否还在、端口 8080 是否健康）＋ `kubectl -n secrets-manager get pods -o wide`（cache 污点 revert 后 operator 到底落在哪个节点）
10. 三集群的 cache 独占节点口径：`kubectl get node 172.16.0.37 10.0.1.220 192.168.1.49 192.168.1.191 --show-labels` + `kubectl describe node | grep -A3 Taints`（label/taint 组合在各集群并不一致）
