# 新集群接入 Runbook（从零到"任务进去就能跑"）

配套：`cluster-capability-matrix.md`（服务/诉求总表 + 依赖关系列）。
文中 `/root/...` 为取证时的本地运维机路径；`ascend-ci-deployment` = https://github.com/opensourceways/ascend-ci-deployment 。
**约束**：本 runbook 的编写全程只读；所有需要登集群的动作只写步骤与只读验收命令，由有权限的人执行。

---

---

## 分层交付模型（新集群按层交付，层间设门禁）

> 核心原则：**L1 公共服务一次装好、不区分社区；社区差异全部下沉到 L2；仓库差异全部下沉到 L3。**
> 与上面阶段的对应关系：阶段 0–1 = L0，阶段 2 = L1，阶段 3 前半 = L2、后半 = L3，阶段 4 = L3/L4。

**L0 底座（集群级，一次性）**
节点装机：驱动 + ADR + Device Plugin、containerd（双格式镜像加速）、openEuler resolv 软链、chrony/HTTP-Date 兜底、镜像预缓存、CNI 模式、apiserver ELB + certSANs、安全组与 NGFW 域名白名单、SFS/NFS/ELB 等外部资源。
门禁（全绿才进 L1）：`date -u` 正确｜`allocatable` 里 NPU 资源名已确定｜CoreDNS forward 可解析外部域｜squid 需要的出网域名已放行｜`kubectl get nodes` 无 NotReady。

**L1 公共服务层（不分社区，装完全集群共享）**
按序：`S19 pull secret` → `S20 vault/secret-manager` → `S13 squid`（`caNamespaces` 先给平台 ns，社区 ns 在 L2 追加）→ `S14 nginx-pypi-cache`（svc 名与端口原样复刻）→ `S16 gh-proxy 验证` → `S15 git-cdn`（单副本）→ `S11 sfs-local-provisioner` + storageClass → `S3/S4/S5/S6`（设备+调度栈，含 LWS）→ `S7 Liqo`（如需）→ `S8 Karpenter`（先容忍后污点）→ `S1 ARC controller` → `S21 buildkitd` → `S22 观测/清理组件`。
门禁：**与任何社区无关的公共冒烟** —— 起一个临时 pod 依次验证：`curl -x squid` 通 + CA 校验通过、`pip install -i <cache-service>` 命中 `X-Cache`、`git clone https://github.com/...` 走 git-cdn 且非零速断连、`buildctl build` 成功、`nvidia/npu` 资源申请成功、中心能看到该集群指标。

**L2 社区接入层（每个社区一次）**
- 建社区 ns + **共享缓存盘**（hostPath `/mnt/sfs-local/<share>` 或 PVC，**命名沿用跨集群同名约定**）
- **权重/数据集同步**：跑零卡 runner 或 `sync-tools` 把模型/数据集预置进盘；云下走 `hf-mirror.com`，HK 走 `huggingface.co`；完成后核对只读子目录（`huggingface/`、`modelscope/`）存在
- Queue capability/deserved 卡数配额、是否要独立卡池（`dedicated=night`/`752t`/`single-node`）
- **登记台账**（见下表）：哪个社区、在哪个集群、哪个 share、权重就绪与否、由谁确认
- 门禁：台账该行"权重就绪 = 是" + 抽查一次 `ls /root/.cache/modelscope/hub/models` 命中；否则该社区的离线类用例不许开放

**L3 项目接入层（每个 org/repo）**
runner scale set（标签与 `runs-on` 严格一致 + 标签手册登记）→ RBAC/SA → `github-app-secret.yaml`/`github-token-secret.yaml`（Vault 侧先有 key）→ `obs-cache-secret` → `squid-injection.py inject`（values + job PodTemplate 双侧）→ `git insteadOf` → 仓库侧 secrets/vars → 冒烟。
门禁：RA/RC 覆盖检查通过 + 该仓库冒烟任务绿。

**L4 运营层（持续）**
时间窗执行与摘除（谁打谁摘）、发布窗口门禁（`nginx-cache-rollout-gate.py`）、两类清理任务（runner 僵尸 / 模型缓存）、告警值班、**台账维护与新社区追加**。

---

## 社区层接入台账（现网已取证部分，新集群照此填写）

| 社区 | 集群 | 共享缓存盘（`/mnt/sfs-local/<share>` 或 PVC） | 权重/数据通道 | 离线依赖 | 状态 / 缺口 |
|---|---|---|---|---|---|
| vllm-project（vllm-ascend、vllm-omni，含 nv-action fork） | gy-001、gy-005、hk-001、cn12、gy-003、gy-006、sh-001 | `vllm-ascend-az5`、`gy005-az5-vllm-ascend-v2`、`vllm-project-hk001`、`nv-action-vllm-benchmarks-v2/-v3`、公共大盘 `ascend-ci-share-nv-action-vllm-benchmarks` | `/mnt/weight`、`/mnt/share`（sh-001/002 系）；`modelscope download` 清单 `misc/model_dataset_list.json`（a2/a3/310p/a5 分池） | vllm-omni `HF_HUB_OFFLINE=1`；vllm-ascend `VLLM_USE_MODELSCOPE` | 已登记。**大盘被 5+ 社区共用**，新集群要按公共盘对待 |
| sgl-project（sglang、sglang-omni、sgl-kernel-npu）+ Ascend/sglang | hk-001、cn12、gy-004、sh-002 | `sgl-project-sglang-v2/-v3`、`sglang-guiyang004`、`ascend-ci-share-pkking-sglang`、`sgl-project-sgl-kernel-npu-liqo-v2`、`sglang-npu-sglang-v2/-v3` | `/data`（CPU job 缓存）；性能用例硬编码 `/root/.cache/modelscope/hub/models/...` 绝对路径 | 未见 `HF_HUB_OFFLINE`，但用例路径依赖预置 | 已登记。sh-002 走自建 NFS（`179.130.11.2`） |
| volcengine（verl、uni-agent、verl-SpeCo、verl-omni） | hk-001、mind-third-ci、verl-suzhou、cn12、gy-001 | `hk001-v1`（整盘）、`verl-hb003`、`verl-project-liqo-cn12-001-v2`、`verl-uni-agent-hk001`、`verl-verl-speco-hk001`、`verl-project-verl-omni-gy001` | `/nfs/verl_ci`（suzhou）；数据集断言 `modelscope/hub/datasets/...` | ModelScope（`ms=Y`）+ 只读试点 runner（只挂 huggingface/modelscope 子目录） | 已登记。**三集群同名 hostPath 约定**，gy004 曾因名字错位卡死 |
| Ascend（pytorch、sglang、cann-container-image、docs、ray-ascend） | cn12、aiframework、gy-005、sh-002、gy-001、hk-001 | `ascend-ci-share-pkking-pytorch`、`ascend-pytorch-share-pvc`、`gy005-az5-vllm-ascend-v2`、`ascend-cann-container-image`、`ascend-docs-cn12-001`、`hk001-v1` | `/data`；pytorch 产物走 `obs://pytorch-ci-cache` | — | 已登记。sh-002 自建 NFS |
| triton-lang/triton-ascend（含 TecJesh、xuedinge233 fork） | cn12、hk-001、gy-001、gy-005、sh-002 | `ascend-triton-ascend-gy005`、`ascend-triton-ascend-hk001`、`triton-ascend-cn12-001-pvc`、`ascend-ci-share-nv-action-vllm-benchmarks` | 大文件走 OBS（Bisheng 编译器、wheel），非权重盘 | — | 已登记 |
| tile-ai（tilelang、tilelang-mlir-ascend） | sh-002、cn12 | `tile-ai-tilelang-share-pvc`、`tile-ai-tilelang-ascend-gy005`、自建 NFS | — | 明确不用远端缓存，靠宿主 `runner.tool_cache` + ccache | 已登记。新集群需给本地大盘，否则退化裸编译 |
| alibaba/ROLL、areal-project/AReaL | cn12 | `alibaba-roll-cn12-001`、`alibaba-roll-liqo-cn12-001-v2`、`areal-project-areal-shared-v3` | — | — | 已登记（AReaL 整盘挂载） |
| HK a2 系（fla-org、hiyouga、modelscope、pt-ecosystem、UsernameFull） | hk-001 | `hk001-v1`（多社区共用整盘）、`fla-org-flash-linear-attention-a2-hk-001` | `MODELSCOPE_CACHE`；`HF_TOKEN`+`hf-mirror` | — | 已登记。**同盘并发写 → NFS flock 不互斥风险** |
| 平台/组织级（ascend-gha-runners、cosdt、GanDing、opensourceways、agentic、cosdt-ci-test） | 13+ 集群 | `ascend-ci-share-ascend-gha-runners`、`ascend-gha-runners-gy001`、`ascend-gha-runners-vllm-ascend-gy006`、`cosdt-ci-test-gy001`、`opensourceways-gy001`、`ganding-rlinf-a2-hk-001`、`ascend-ci-share-cosdt`、gy-006 静态 PV `pvc-<uuid>` | `/mnt/weight`（sh-001）；`sync-tools` 是跨集群同步的执行者（`nv-action-vllm-benchmarks-v3`、`sgl-project-sglang-v2`） | — | 已登记 |
| **gitcode / 内部租户（mindspeed 系、megatron-adaptor、op-plugin、cann、fsdpturbo、memfabric/memcache、六个 SDK + mindstudio、slime-ascend、openubmc、ascend-datasync、argo）** | gy-001、gy-002、wlcb-001 | **待登记** | 待登记；wlcb 的 `ascend-datasync` ns 看名字就是专职数据同步，可先从它要台账 | 待登记 | **最大缺口**：集群侧只能证明它们拿到 squid CA，其余需各团队给清单 |

---

## 阶段 0：定形态与唯一输入（纸面，1 天）

1. **选集群形态**（决定装不装 ARC/vault/buildkitd）：
   - 全功能 CI 集群（对标 hk-001、cn12-001）
   - 纯 Provider（对标 wlcb-001）：Liqo + npu-scheduler + 出网三件套 + provider 侧同名 PVC/RBAC + exporter
   - 纯基础设施出口（对标 gy-002）：只有 squid + 监控，供别的租户用
2. **写 `cluster.yaml`（新集群唯一输入）**，必填字段：
   - region/云、节点 arch（是否有唯一 x86 节点）、OS（openEuler / Ubuntu）
   - NPU 型号、卡数、**实际注册的资源名**（以 `kubectl describe node` 的 allocatable 为准，不以机型手册为准）
   - CNI（Cilium/Calico、是否 native routing、是否 VPN 多网卡）
   - apiserver 入口：内网地址 + 公网 ELB/EIP + **certSANs 全集**
   - 存储：storageClass 类型（`sfsturbo-subpath-sc` / `csi-sfsturbo`+share-id / 自建 NFS / hostPath / `harbor-subpath-sc`）+ share 名清单
   - 出网：是否被 NGFW 域名白名单限制、公网出口 IP（给中心 CN4 放行用）
   - 控制面归属：中心 ArgoCD 还是该集群自建（现网存在 `destination: in-cluster` 的第二套控制面）
   - **承载哪些业务**：从总表 23 列里勾选（含 14–23 的 gitcode/内部租户）
3. **立刻发起外部申请**（日历时间最长，别等到装组件时才提）：SFS/EVS 盘与 share-id、ELB/EIP、安全组端口、NGFW 域名放行、Harbor/SWR 命名空间、Vault KV 录入、中心监控放行 `113.44.182.82:9090/9091`。

## 阶段 1：节点与底座

4. 节点装机（可复用 `resource-deploy-core` 的探测/join/`deploy_softwares` + 现网装机模板）：
   - 昇腾驱动 + Ascend Docker Runtime + Device Plugin，**版本必须配套**（不配套 → `dcmi init failed -8255`）
   - containerd 镜像加速：v1.6 用 config.toml 老式 mirrors；v2.x 用 `certs.d/hosts.toml`，**改完必须重启 containerd**
   - openEuler 无 systemd-resolved → 预置 `/run/systemd/resolve/resolv.conf` 软链（否则 pod sandbox 创建失败）
   - 时钟：chrony；UDP123 被封则部署 HTTP-Date 兜底 timer。装完必查 `date -u`（偏 8h → GitHub App JWT 401、listener 无限崩）
   - 镜像预缓存：pause、CNI、runner、busybox；legacy 业务还要求节点预置 `imagePullPolicy: Never` 的镜像
   - 验收（只读）：`date -u`、`npu-smi info`、`kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable}{"\n"}{end}'`、`crictl images`
5. 网络与存储：
   - CNI 模式按拓扑选（VPN/多网卡不要硬上 native routing）；lab 节点补 SNAT/masquerade
   - 安全组：10250、CNI 端口（4240/8472）、NodePort 段
   - 按 share 名准备 NFS/SFS 导出，并挂/bind 成 `/mnt/sfs-local/<share>`（**名字要与既有集群一致**，Liqo 按名字映射）
   - 若沿用"缓存单点"模式：给缓存节点打 `cache=true` label（±污点，各集群不一致，按 cluster.yaml 决定）

## 阶段 2：平台组件（按依赖顺序，每步验收再下一步）

6. ArgoCD 侧先做两件事：注册集群 cluster secret（destination 名 = cluster.yaml）；**把 AppProject 写进 Git**（当前仓库里没有任何 AppProject 定义，属隐性依赖）。
7. 安装顺序（依赖列推导出的拓扑序）：

   1. S19 SWR + pull secret（几乎所有组件硬引用该 secret 名，最先做）
   2. S23 时钟/DNS、S18 白名单（工单类，并行推进）
   3. S3 驱动 + Device Plugin → 校验资源名
   4. S20 Vault / secret-manager（Vault 侧 KV 必须已有内容）
   5. S13 squid（`caNamespaces` 列全所有消费方 ns，含 gitcode 租户）
   6. S14 nginx-pypi-cache（**svc 名与端口必须与现网一致**；容量按本集群核定，不许照抄）
   7. S16 gh-proxy 可达性验证 → S15 git-cdn（单副本；需要 gitcode 再加一份实例或 smart-git-proxy）
   8. S11 sfs-local-provisioner（要 `cceaddon-volcano` 豁免标签）→ S9 共享缓存盘 / S10 权重盘 / S12 work PVC
   9. S4 npu-scheduler → S5 volcano + Queue → S6 LWS
   10. S7 Liqo（consumer/provider 二选一或both；两侧 `networking.enabled` 一致）
   11. S8 Karpenter（**先给 runner 加 toleration，再给 NodePool 加污点**）
   12. S1 ARC controller（镜像架构匹配，0.14.201 仅 amd64）
   13. S21 buildkitd（需 S20 证书 + S13 CA 分发到 buildkitd ns + `devic.es/fuse` + 节点 seccomp profile）
   14. S22 观测与治理：node-exporter（静态 IP 列表）→ kube-state-metrics → prometheus-agent（出口被掐则装 pushgateway-local，**版本 v1.10.x**）→ npu-exporter-ascend → zombie-runner-cleanup → **补装 `model-cache-cleanup`、`nginx-conf-drift`（现网无 GitOps 清单，最容易漏）**
   15. 验收（只读）：`kubectl -n squid|nginx-pypi-cache|git-cdn|buildkitd get svc,pods`、`kubectl get sc`、`kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints`

## 阶段 3：业务接入（按总表逐列）

8. 建 `projects/<org>/<repo>/config-for-<cluster>/`（namespace、PVC、RBAC、PodTemplate ConfigMap）+ `linux-<arch>-<npu>-<n>-<cluster>/values.yaml` + `argocd/clusters/<cluster>/*.yaml`；runner 标签登记进 runner-name 手册（`check-projects-coverage.py` 的 RA/RC 门禁会拦）
9. 用 `scripts/squid-injection.py inject <runner_dir>` 注入代理与 CA（**同时改 values.yaml 和 job PodTemplate**，只改前者 = job 仍直连），再 `check` 做回归
10. 补凭据与盘：`obs-cache-secret`、`github-app-secret.yaml`（Vault 里先有 key）、共享盘/权重盘、legacy 栈的镜像预缓存
11. GitHub 仓库侧 secrets/vars：`KUBECONFIG_*_B64`（含 cluster 级 `nodes` patch 那份）、`A2/A3_TAINT_NODES`、`SWR_USERNAME/PASSWORD`、`OBS_*`/`HW_OBS_*`、`QUAY_*`、`NIGHTLY_COMMAND_BLOCK_WINDOW`
12. 模型/数据集预热：零卡 runner（`*-0`）+ 清单驱动下载，或 sync-tools 跨集群同步；云下用 `HF_ENDPOINT=hf-mirror.com`；完成后核对只读子目录（huggingface/modelscope）存在
13. 时间窗协作落纸面：谁在什么时间打 `dedicated=night`、CI 何时摘（现网是集群侧打 + 业务 workflow 的 `remove-taints` 摘）

## 阶段 4：验收与交付

14. 冒烟 5 条，一条不能省：CPU lint job（S1+标签+S8）／单卡 NPU 测试（S3+S4+资源名）／多机 LWS（S5+S6+R1+S9）／走 squid 的 pip 安装 + docker build（S13+S20+S21+S19）／离线模型加载（S10+R4）
15. 跑 doctor（只读体检）：污点全集、allocatable 资源名 vs 业务 requests、`/mnt/sfs-local` share 清单、各 svc 与端口可达性、拨测目标是否与业务实际用的代理一致（gy-001/wlcb 教训：探的是遗留 `git-cache-github:8080`）、清理类 CronJob 是否存在
16. 回写文档：总表新增集群行/列、runner 标签手册、`cluster.yaml` 入 GitOps

---

## 决策点清单（18 项：一次性参数 12 + 持续运营 6）

**一次性参数（填进 cluster.yaml 就能自动往下走）**
1. 集群形态（全功能 / 纯 Provider / 纯出口）
2. 承载业务清单（总表 23 列勾选）→ 决定 caNamespaces、Queue、标签、盘
3. NPU 资源名口径（以 allocatable 实测为准）
4. CNI 模式（tunnel vs native routing）
5. 存储方案与 share 命名（是否沿用跨集群同名约定）
6. nginx 缓存容量 `max_size`（每集群单独核定）
7. squid registry 白名单 + urlRewrite 域清单
8. squid CA 用 `_prod_pem` 还是试验田 key（跨集群复用会 TLS 失败）
9. Queue capability / deserved 卡数配额
10. Karpenter 机型/上限/是否带 `cpu-elastic` 污点
11. ARC 版本与镜像架构（arm-only 不能用 0.14.201）
12. 多机路线：装 LWS 还是走 RayJob（verl 那种）

**持续运营（脚本只能执行，不能替决策）**
13. 时间窗归属：谁打污点、什么时间、谁兜底摘除
14. 出网白名单范围：NGFW 域名清单、中心监控放行 IP
15. 驱动/ADR/DCMI/Device Plugin 版本矩阵确认
16. Vault KV 内容由谁录入、GitHub App 授权范围
17. 是否支持 legacy 业务（`imagePullPolicy: Never` → 节点预缓存策略）
18. 放行标准：冒烟 5 条是否作为上线门槛

## 可脚本化清单（41 项：现成 9 / 需新写 12 / 半自动 14 / 纯人工 6）

**已现成，直接可用**：helm+kustomize 装 22 项 infra ｜ `squid-injection.py`（audit/inject/revert/check）｜ `argocd-app-lint.sh` ｜ `check-projects-coverage.py`（RA/RC）｜ `tests/`（配置漂移、toleration 断言）｜ `nginx-cache-rollout-gate.py`（发布门禁）｜ monitoring overlay 模板 ｜ `resource-deploy-core`（节点探测/join/软件下发/TTL 清理）｜ GitOps 同步本身

**需要新写（一次写好长期复用）**：`cluster.yaml` schema+校验器 ｜ ApplicationSet / root-app 生成器（**当前仓库 0 个 root app、0 个 ApplicationSet、0 个 AppProject 定义**）｜ 每集群 values 渲染（SC/cache 节点/CA key/镜像 tag/toleration）｜ sync-wave 顺序编排 ｜ `new-cluster-doctor.py`（只读体检）｜ 冒烟触发与结论汇总 ｜ GitHub secrets/vars 批量下发 ｜ Vault 写入脚本 ｜ AppProject 模板化 ｜ 装机 playbook（containerd 双格式、resolv 软链、时钟兜底、镜像预缓存清单）｜ `model-cache-cleanup`/`nginx-conf-drift` 补 GitOps ｜ runner 标签手册自动登记

**半自动（脚本能起草，但要云 API 权限或工单）**：SFS/EVS 建盘与 share-id ｜ ELB/EIP + certSANs 重签 ｜ 安全组端口 ｜ NGFW 域名白名单申请 ｜ 中心 CN4 放行 ｜ Harbor/SWR 命名空间与机器人账号 ｜ Vault 服务端 policy/role（`buildkitd` SA 名不可改）｜ Liqo 两侧 peer 与可达性验证 ｜ 集群注册进 ArgoCD ｜ 模型权重重下载/跨集群同步 ｜ 驱动与 device plugin 装机 ｜ 节点 label/taint 初始化 ｜ NFS 目录预导出+chmod ｜ 只读缓存子目录核对

**纯人工/流程**：业务清单与配额谈判 ｜ 时间窗归属 ｜ 版本矩阵确认 ｜ 发布批准 ｜ gitcode 租户诉求收集（总表 14–23 列的 `?`）｜ 验收签字

**一句话结论**：先做"需要新写"里的前 5 项（schema、ApplicationSet、doctor、冒烟、secrets 下发），手工动作可从 ~40 次降到 ~8 次；剩余瓶颈是那 14 个云 API/工单类动作 —— 属日历时间，必须 T-7 天前发起，写脚本也不会变快。
