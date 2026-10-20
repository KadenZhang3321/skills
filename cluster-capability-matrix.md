> 说明：文中 `/root/...` 为取证时的本地运维机路径；`ascend-ci-deployment` = https://github.com/opensourceways/ascend-ci-deployment

# 集群能力 × 业务诉求 总表（为新集群"任务进去就能跑"）

**图例**：`●●` 硬依赖（缺了跑不起来，配置里硬编码）｜`●` 需要（有兜底/只影响速度）｜`▲` 该业务特有｜`—` 不适用｜`?` 待取证
**业务列**：1–13 = GitHub 仓库 CI（证据：`ascend-ci-deployment/projects|other` + 各仓库 `.github/workflows`、`.buildkite`）；14–23 = **gitcode / 内部仓库租户**（证据：`argocd/clusters/squid-rpardini/values-{gy-001,gy-002,wlcb-001}.yaml` 的 `caNamespaces` 名单 —— 这些命名空间不是本仓库部署的，其 CI 定义在 gitcode/内部流水线，本地无仓库，故多数格为 `?`，需向对应团队收一次诉求清单）
**行**：纵向 = 基础设施提供的服务（S*）+ 业务侧诉求（R*）

## 服务与诉求速查（先看懂这些，再查总表）

| 编号 | 用途 / 目的（一句话） | 缺了或做错会怎样（现网实证） |
|---|---|---|
| S1 ARC 自托管 runner | 把 GitHub Actions 的 job 落到 K8s + NPU 节点上执行 | 没有它 CI 无处运行；`runs-on` 标签与 scale set 标签不一致 → job 永远 waiting |
| S2 租户自建 CI 引擎（Argo 等） | 不走 GHA 的内部/gitcode 租户自带流水线，集群只供算力与出网 | 按 ARC 思路给这类集群装 runner 属于白装，需求方用不上 |
| S3 NPU 驱动 + 设备插件（资源名） | 让 pod 能申请到具体的卡（`ascend-1980`/`npu`/`Ascend910`/`ascend-310`） | 资源名写错（曾写 `huawei.com/ascend-a5`）→ volcano 永久 Unschedulable；驱动/ADR/DCMI 版本不配套 → `dcmi init failed -8255` |
| S4 npu-scheduler | runner 层按卡槽位与 runner 同步选节点，避免多个 runner 抢同一张卡 | runner 落错节点、卡冲突、Pending；nightly 需要 `-nofifo` 变体 |
| S5 volcano + Queue | job 层 gang 调度（整机多卡一起成功或一起等）+ 按团队配额 | 无 gang → 多机任务半启动死锁；无 queue → 一个业务吃光全集群卡 |
| S6 LeaderWorkerSet | 编排"1 leader + N worker"的多机推理 / PD 分离形态（含 headless service） | 多机 nightly 与 PD 分离测试无法创建，控制器 job 里 `kubectl apply` 直接报 no resource |
| S7 Liqo offloading | 把 A 集群的 pod 甩到 B 集群的卡上跑（跨集群借卡） | 卡不够时无处溢出；两侧 PVC/hostPath 不同名 → offload pod 卡死（gy-004 曾发生） |
| S8 Karpenter 弹性 CPU 池 | CPU 类 job（lint/构建/控制面）高峰扩 ECS、闲时缩回 | 常驻节点被基础服务占死、弹性节点缩不回；顺序搞反（先加污点）→ 存量 pod 全 Pending |
| S9 共享缓存盘 `/root/.cache` | pip 包、pre-commit、日志、模型缓存跨 pod / 跨 job 复用 | 每个 job 重下几十 G；439G 权重被误标删除后当晚全量重下的事故 |
| S10 模型权重盘 / 公共大盘 | 离线跑测所需的模型与数据集仓库（`/mnt/weight`、`/mnt/share`、nv-action 大盘） | `HF_HUB_OFFLINE=1` 类任务直接失败；只读试点 runner 拿不到 huggingface/modelscope 子目录 |
| S11 sfs-local-provisioner | 把 SFS export 挂到节点再 bind 成 `/mnt/sfs-local/<share>` 供 job 以 hostPath 使用（顺带防 NFS 根穿） | 弹性/新节点的挂载窗口导致 FailedMount；DaemonSet 不打 `cceaddon-volcano` 豁免标签会被 gang 连坐 |
| S12 独立 work PVC（本地盘 / subpath） | 单 job 的工作区与编译中间物，避免挤占共享盘 | ephemeral-storage 不足被驱逐、构建中途失败 |
| S13 squid（SSL-Bump 代理 + registry 缓存） | 集群唯一受控出网口 + 镜像层/包缓存，替代逐个申请公网白名单 | pip/docker/GitHub release 全超时；CA 指纹与客户端不一致 → TLS 握手失败；squid 挂 = buildkit 的 RUN 全 502（SPOF） |
| S14 nginx-pypi-cache | 仓库内的多生态包缓存（pypi / torch / ascend repos + deb/rust/yum/go/crates 分端口） | CI 装依赖走公网，慢且不稳；现网 workflow **硬编码该 svc 名与端口**，改名等于业务全红 |
| S15 git-cdn（GitHub） | 缓存 git smart-HTTP pack 与 LFS，让大仓 clone 又快又可重试 | 国内集群直连 github 被 WAF 掐（TLS 超时断连），大仓 checkout 反复失败 |
| S16 gh-proxy / gitcode 通道 | GitHub release/raw 与 gitcode 仓库的另一条加速与取源路径 | gitcode 系租户拿不到源码与发布物；`clientMaxSize` 没调大则 push 报 413 |
| S17 OBS/S3 通道 | 跨集群远端缓存（pre-commit/csrc）+ 制品与测试基线（精度用例、coverage、wheel 索引） | cache miss 触发全量重编译；精度/覆盖率基线缺失导致用例筛选失效 |
| S18 各类白名单（出网/入网/中心） | 让链路可控：NGFW 域名白名单、安全组端口、apiserver ELB 白名单、中心监控放行 | 云下出口"默认丢弃"→ 拨测与 remote_write 静默断链、`GitHubProxyUnreachable` 假告警 |
| S19 SWR 私有仓库 + pull secret | 分发昇腾定制镜像（runner / controller / ci-probe / nginx_pypi_cache 等） | 所有 pod ImagePullBackOff；arm64 集群撞上 amd64-only 镜像 → exec format error |
| S20 Vault + secret-manager | 集中托管并下发凭据（GitHub App/token、OBS AK/SK、squid CA、buildkit 证书） | runner 拿不到 GitHub 凭据 → listener 无限崩重建；SecretDefinition 缺失 → scale set 起不来 |
| S21 buildkitd + dispatcher + KEDA | 集中式镜像构建后端（mTLS、队列租约、按需扩容），业务侧无需特权 docker | CPU runner 里只能走 rootful/privileged 构建，风险大且互相挤占资源 |
| S22 观测与治理任务 | 指标汇聚到中心 + 拨测 + NPU exporter + 僵尸 runner 清理 + 模型缓存清理 | CI 卡住/红灯无从定位；僵尸 EphemeralRunner 占坑挡住后续 job；缓存盘被撑爆 |
| S23 NTP 时钟 + CoreDNS forward | 保证时间一致与域名可解析（节点与 pod 两层） | 时钟偏 8h → GitHub App JWT 401、listener 无限崩；CoreDNS 上游不可达 → pod 内解析失败、pip/git 全线超时 |
| R1 时间窗 / 独占污点 | 用污点把夜间池、整机池、缓存节点圈出来，防止被普通负载抢走 | nightly 长任务被白天 PR CI 打断；缓存服务被挤到 NPU 节点上 |
| R2 nodes patch 权限（kubeconfig） | 让业务 CI 能在时间窗结束时**摘掉污点**、把节点放回公共池 | 只有 toleration 没有摘污点能力 → 节点被永久独占（现网 workflow 的 `remove-taints` job 正是干这个） |
| R3 零卡 runner（`*-0`） | 纯控制面 runner：跑 kubectl/LWS 编排、Ray 提交、模型下载，不占卡 | 编排任务挤占 NPU runner，或因卡数不匹配调度失败 |
| R4 模型/数据集下载链路 | 把权重与数据集预置进共享盘（清单驱动 + 限速 + 专用节点） | 测试首次运行就要联网下几十 G；云下集群根本连不上 huggingface |
| R5 编译缓存（ccache/csrc/pre-commit） | 避免每个 job 重编 C++ / LLVM / 算子 | triton-ascend 明确注释：并发开高就 OOM、并触发 buildkitd/SWR 认证超时 |
| R6 apt/系统装包能力 | CI 需要 git/jq/clang/gh/docker CLI 等系统包 | 装包失败=后续步骤全红；openEuler 与 Ubuntu 还要分别走 8083/8081 |
| R7 privileged / hostNetwork / 设备直通 | 整机卡直通、跨节点通信端口、DinD | ms-swift、verl、sglang-PD 这类用例跑不起来（EAI_NONAME、拿不到 `/dev/davinci*`） |
| R8 镜像构建与推送 | 产出 nightly/release 镜像并推到 SWR/quay/docker.io | 业务没有可用运行镜像，CI 自身与下游用户都断供 |
| R9 维护窗口与发布门禁 | 滚动缓存/代理组件时先让 CI 空跑，避免自杀式断流 | 发布即打断在跑 job；cn12 属"重型窗口"，必须暂停 CI + 暂停 Argo 同步 |
| R10 仓库侧 secrets/vars 预配 | 凭据与变量先就位（kubeconfig、OBS、SWR、taint 节点清单、窗口开关） | 缺一项就是一片 job 起不来，或编排步骤 401/403 |

---

| # 服务 / 诉求 | 1 vllm-ascend（含 nv-action fork） | 2 vllm-omni | 3 vllm-ascend-recipes | 4 sglang（sgl-project+omni+Ascend/sglang） | 5 sgl-kernel-npu | 6 triton-ascend | 7 tilelang（+mlir） | 8 verl（+uni-agent/SpeCo/omni） | 9 Ascend/pytorch | 10 ms-swift | 11 LLaMA-Factory | 12 FLA | 13 ROLL + AReaL | 14 MindSpeed 系（llm/mm/bridge/ops） | 15 Megatron-Adapter | 16 OpPlugin + CANN | 17 SDK 系（vision/driving/rag/rec/index/multimodal + MindStudio） | 18 FSDPTurbo | 19 MemFabric/MemCache | 20 SLIME-Ascend | 21 openUBMC | 22 ascend-datasync | 23 Argo 流水线租户 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **▍服务类｜平台对外提供的能力（业务直接调用的入口）** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| **S1 ARC 自托管 runner** | ●● | ▲ Buildkite agent-stack | ●● | ●● | ●●（新旧两代栈） | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ▲ 自建 CI（非 ARC） |
| **S2 CI 引擎自带（Argo Workflows/Woodpecker）** | — | — | — | — | — | — | — | — | — | — | — | — | — | ? | ? | ? | ? | ? | ? | ? | ? | ? | ●●（gy-001/gy-002/wlcb 均有 `argo` ns） |
| **S13 squid 出网代理 + CA 注入（`squid-ca-cert` + 6 个 CA env + `NO_PROXY` 绕 GHA 控制面）** | ●● 全套 | ●● | ● | ●● | ●● | ●●（buildkit 模板） | — | ▲ 裸 IP 代理 `100.68.174.87:3128`（GPU 线） | ● | ● | ● | ● | — | ●●（ns 在 `caNamespaces` 名单内） | ●● | ●●（含 `.gitcode` 绕行需求） | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **S14 nginx-pypi-cache（`/pypi` `/whl` `/ascend/repos` + 8081 deb/8082 rust/8083 yum/8084 go/8085 crates）** | ●● pip+whl+ascend+apt | ●● | ●● | ●● pip+whl+rust（+三级回退） | ●●（56 处引用） | ●● pip+ascend extra-index | ▲ 反例：不用远端缓存，走宿主 `runner.tool_cache` | ●● pip 硬编码无回退 | ●● | ●● pip+apt | ●● pip+apt | ▲ 用 `triton-ascend.osinfra.cn/pypi/simple` | ●● | ? | ? | ? | ? | ? | ?（`memfabric-*/memcache-*` 走 huaweicloud ascend repos，sglang 安装脚本即证据） | ? | ? | ? | ? |
| **S15 git-cdn（github）** | ●● `git-cdn-service:8000` | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ● | ● | ● | —（裸 clone github） | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S16 gitcode / gh-proxy 通道（`gh-proxy.test.osinfra.cn`、`git-cdn-gitcode`、`smart-git-proxy`）** | ●● | ● | ● | ●●（release/zip） | ●●（28 处） | ●● | ● | ●● + `gitcode.com/Ascend/FSDPTurbo` 直连 | ● | ● | ●（`requirements/fsdpturbo.txt` git+gitcode） | ● | ▲ 直连 github 不走代理 | ? | ? | ▲ gitcode 主源（`NO_PROXY` 绕 `gitcode.com`） | ? | ●●（仓库本体在 gitcode） | ? | ? | ▲ gitee/atomgit 镜像构建 | ? | ? |
| **S17 OBS/S3 通道（远端缓存 + 制品基线 + 大文件源）** | ●● `ascend-ci-cache-hk`（`RUNS_ON_S3_BUCKET_*`）+ precision-test 基线 | — | — | ▲ `sglang-npu.obs` coverage 基线 | ● | ●● `triton-ascend-artifacts.obs`（Bisheng 编译器+sha256+断点续传） | — | ● 基线走 `raw.githubusercontent.com` | ●● `obs://pytorch-ci-cache`（唯一产物通道） | — | — | — | ● actions-cache | ? | ? | ●● `obs-cache-secret` | ? | ? | ? | ? | ? | ●● 数据同步本体 | ? |
| **S19 SWR 私有镜像 + `huawei-swr-image-pull-secret-model-gy`（含 quay.io/docker.io 双向）** | ●● 双 pull secret | ●● | ●● | ●● SWR+docker.io | ●●（`model-cn12`） | ●● SWR+quay | ●● SWR | ●● SWR+quay | ●● SWR(cn-north-4) | ●● docker.io | ●● docker.io+quay | ●● docker.io | ●● quay.io | ? | ? | ●● | ? | ? | ? | ? | ? | ? | ? |
| **S20 Vault / secret-manager（GitHub App、OBS AK/SK、buildkit 证书、TLS）** | ●● | ●● buildkite token | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ? | ? | ●● | ? | ? | ? | ? | ? | ? | ? |
| **S21 buildkitd 远程构建（mTLS + dispatcher + KEDA + fuse）** | ●●（hk cpu-16/32） | — | — | ● | ● | ●●（`cpu-4-buildkit` 专用 runner） | — | — | — | — | — | — | — | ? | ? | ●●（CANN 镜像构建本体） | ? | ? | ? | ? | ? | ? | ? |
| **▍资源类｜算力 · 存储 · 调度（决定任务能不能落到卡上）** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| **S3 NPU 驱动 + 资源名**（`ascend-1980`/`huawei.com/npu`/`Ascend910`/`ascend-310`/vNPU 切片） | ●● 全谱+vNPU | ●● | ●● a2b4/a5/800i | ●● a3/800t/a5 | ●● a3/800i/800t/a5+旧 `npu-*` | ●● | ●● A5 | ●● `Ascend910`/1980 | ●● a3/800i/a5 | ●● a2 | ●● a2 | ●● a2 | ●● a3/800i | ?（整机多卡） | ? | ? | ? | ? | ? | ? | — | ? | ? |
| **S4 npu-scheduler（runner 层）** | ●●（+`-nofifo`） | ●● | ●● | ●● | ●●（含旧 `runner-pod-npu-scheduler`） | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S5 volcano gang + Queue 配额** | ●● `vllm-queue` | ●● | ● | ●● `sglang-queue`/`sglang-npu-cn12-queue` | ●● `sgl-kernel-npu-cn12-queue` | ●● | ●● | ●● `verl-queue` | ●● | ●● | ●● | ●● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S6 LWS（多机 gang）** | ●● nightly 多机 | ● | ● | ●● PD 分离 | ● | — | — | ▲ RayJob `rayjob-submitter.ci-system.svc` | — | — | — | — | ●（Ray 类） | ? | ? | — | ? | ? | ? | ? | — | — | ? |
| **S7 Liqo 跨集群 offload** | ●●（gy-001/wlcb） | ●●（cn12 offload ns） | — | ●（gy-004/aiframework/mind） | ● | ● | — | ●●（`verl-project-liqo` 覆盖 3 集群） | ● | — | — | — | ● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S8 Karpenter 弹性 CPU（`cpu-elastic` 污点）** | ●● | ● | — | ● | ● | ●●（buildkit CPU） | — | — | ●● `cpu-24` 专测 | — | ● | ● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S9 共享缓存盘 `/root/.cache`**（SFS RWX / hostPath `/mnt/sfs-local/<share>` 同名约定） | ●● az5/hk001/nv-action 大盘 | ●● | ●● | ●● pkSING 盘 | ●● | ●● | ●● 自建 NFS | ●● hk001 整盘 + `/nfs/verl_ci` | ●● | ●● | ●● 整盘 | ●● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ▲ 它就是盘的写入方 | ? |
| **S10 模型权重/大盘（`/mnt/weight`、`/mnt/share`、`/data`、共用大盘）** | ●● | ●● 强制离线 | ●● | ●● | ● | ● | — | ●● modelscope 目录断言 | ● | ● | ● | ● | ● | ? | ? | ? | ? | ? | ? | ? | — | ●● | ? |
| **S11 sfs-local-provisioner（bind 到 hostPath）** | ●● | ●● | ●● | ●● | ●● | ●● | ●●(NFS 替代) | ●● | ●● | ●● | ●● | ●● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S12 本地盘/独立 work PVC（`csi-disk`/`sfsturbo-subpath-sc`）** | ●● 64Gi | ●● | ● | ●● | ●● legacy | ● | ● | ● | ● | ● | ● | ● | ● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **▍业务诉求类｜业务自带的需求（不是平台默认就有）** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| **R3 零卡控制面 runner（`*-0`：a3-800t-0 / a2b3-0 / a5-0）** | ●●（LWS 编排 + 模型下载） | ● | ●● | ●● | ●●（`cpu-0`） | ●（buildkit 有 CPU runner） | — | ●●（`a3-800i-0` 多机控制器） | — | — | — | — | ●●（`a3-0` CPU job） | ? | ? | ? | ? | ? | ? | ? | ? | ? | — |
| **R4 模型/数据集下载与预置（`modelscope download`、`HF_ENDPOINT=hf-mirror.com`、`model_dataset_list.json`+PR label 触发、`tc` 限速 pod）** | ●● | ●● 全离线 | ●● | ●●（`SGLANG_USE_MODELSCOPE`） | ● | ●（wheel 为主，模型少） | ●（宿主缓存） | ●●（数据集文件断言 + `HF_TRANSFER=0`） | ●● | ●● `MODELSCOPE_CACHE` | ●● `HF_TOKEN` | ●● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ●● | ? |
| **R5 编译缓存（ccache / pre-commit / csrc / LLVM，受内存与 NFS flock 语义约束）** | ●● pre-commit 走 OBS 远端缓存 | ● | — | ●● rust 扩展 seed-cache workflow | ●● | ●● ccache+`~/.triton/llvm`（OOM 限制并发 ≤6/≤8） | ●● 需 runner 预装 ccache（`-M 20G`） | ● | ●● 宿主 `/data/torchnpu-ccache` | — | — | — | ● | ? | ? | ●● | ? | ? | ? | ? | ●● | ? | ? |
| **R6 apt/系统装包（`sudo apt-get install`、nodesource、docker CLI 预热）** | ●● gh/git/jq | ● | ● | ●●（`npu_ci_install_dependency.sh`） | ●● | ●● clang（+华为云 docker-ce 预热 `install-docker-cli` Job） | ● | ● | ●● openEuler/Ubuntu 双态 | ●● nodesource | ●● | ● | ● | ? | ? | ●● | ? | ? | ? | ? | ? | ? | ? |
| **R7 privileged / hostNetwork / `--device /dev/davinci*`** | ● | ●●×4 | ● | ●● PD hostNetwork+privileged | ● | ●（docker `--network host`） | ● | ●● | ●● 8 卡直通+label 关闭 | ●● 整机 4 卡直通 | ● | ● `--shm-size 16g` | ● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **R8 镜像构建与推送（buildx/QEMU/manifest，推 SWR/quay/docker.io）** | ●● nightly+main2main 镜像 | ● | ● | ●● 多 arch 镜像 | ●● kernel wheel | ●● SWR+quay+obs pypi index | ●（dist 在 hosted） | ●● quay.io/ascend/verl | ●● SWR frameworkptadapter | ●● docker_npu | ●● docker.io+quay | — | — | ? | ? | ●● CANN 容器镜像 | ? | ? | ? | ? | ●● | ? | ? |
| **▍运营类｜治理、保障与协作约定（做错会大面积变红）** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| **S18 出网白名单（NGFW 域名白名单 / 安全组端口 /  apiserver ELB 白名单 / 中心监控 IP 放行）** | ●●（需 kubectl→apiserver 白名单） | ●● | ●● | ●●（PD 需 8000/8995/HCCL 端口段） | ●● | ●● | ● | ●●（suzhou hostNetwork） | ●● | ●● | ●● | ●● | ●● | ●●（gy-002/wlcb 出口被 NGFW 挡过，拨测才改指集群内 git-cache） | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **S23 NTP 时钟 + CoreDNS forward（`dnsPolicy: None`/resolv.conf 覆写特例）** | ●●（时钟偏 8h→JWT 401） | ●● | ●● | ●● | ●● | ●● | ●● | ●● ▲ 覆写 `/etc/resolv.conf` 指 `10.247.3.10` | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● | ●● |
| **R1 时间窗/独占污点（`dedicated=night`、`752t`、`single-node`、`cache=true`、`node.usage.notes=…download_large_model`）+ **业务 workflow 里定时摘污点**** | ●● 唯一有摘污点逻辑：`schedule_nightly_test_a2/a3.yaml` 的 `remove-taints` job 跑 `kubectl taint nodes ${{vars.A2/A3_TAINT_NODES}} dedicated-` | ● 容忍 | ● | ●●（`dedicated` 在 sglang LWS 模板里） | ●● | — | ▲ `huawei.com/schedule_policy: chip4-node8` | ●（suzhou 独占） | ● | — | — | — | — | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **R2 打污点所需权限（cluster 级 `nodes` patch + 内网 kubeconfig secret）** | ●● `KUBECONFIG_B64`/`KUBECONFIG_HK_001_INTERNAL_B64`/`KUBECONFIG_A5_B64` | ● | ● | ●●（PD 编排） | ● | — | — | ● | — | — | — | — | — | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **R9 维护窗口 / 门禁（`NIGHTLY_COMMAND_BLOCK_WINDOW`、nginx rollout gate、暂停 CI）** | ●● | — | — | ● | ● | ● | — | — | — | — | — | — | ▲ `PREPARE_JOB_TIMEOUT=43200` | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **R10 仓库侧必须先建的 secrets/vars** | ●● `KUBECONFIG_*_B64`、`OBS_ACCESS_KEY_ID/SECRET(_PRECISION)`、`HW_OBS_AK/SK`、`SWR_USERNAME/PASSWORD`、`SYNC_TOOLS_TOKEN`、`PAT_TOKEN`、`QUAY_CI_*`、`A2/A3_TAINT_NODES`、`NIGHTLY_COMMAND_BLOCK_WINDOW` | ● `BUILDKITE token` | ● | ●● `OBS_*`、`QUAY_*` | ●● | ●● `QUAY_*`+APIG AppCode | ● | ●● `DEEPSEEK_API_KEY`、`DEV_SUBMITTER_TOKEN` | ●● `ACCESSKEY/SECRETACCESSKEY` | ●● `MODELSCOPE_API_TOKEN` | ●● `HF_TOKEN`、`DOCKERHUB_*` | ● | ●● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **S22 观测：prometheus-agent→中心 / 拨测 CronJob / npu-exporter / node-exporter / KSM / runner 清理 / 模型缓存清理** | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| **▍分布｜该业务实际跑在哪些集群** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| **实际在跑的集群** | hk-001、cn12、gy-001/003/005/006、sh-001（+wlcb/gy-004 offload） | cn12、hk、gy-003、sh-001 | cn12、gy-001、sh-001 | hk、cn12、gy-004、sh-002 | hk、cn12、gy-004、sh-002 | cn12、hk、gy-001、gy-005、sh-002 | sh-002 | cn12、hk、mind-third、verl-suzhou | cn12、aiframework、gy-005、sh-002 | hk | hk | hk | cn12 | **gy-001、gy-002、wlcb-001**（`mindspeed`/`-llm`/`-mm`/`-bridge`/`-ops`） | **gy-001、gy-002、wlcb-001** | **gy-001、wlcb-001**（`op-plugin`；`cann` 仅 wlcb） | **gy-001、gy-002、wlcb-001**（`visionsdk`/`drivingsdk`/`ragsdk`/`recsdk`/`indexsdk`/`multimodalsdk`/`mindstudio`） | **gy-002、wlcb-001**（`fsdpturbo`） | **gy-002、wlcb-001**（`memfabric-hybrid`/`memcache`） | **gy-001、wlcb-001**（`slime-ascend`） | **wlcb-001**（`openubmc`） | **wlcb-001**（`ascend-datasync`） | **gy-001、gy-002、wlcb-001**（`argo`） |

---

## 这张表读出来的 8 个要点

1. **P0 六件套**（任何业务都缺不了）：NPU 驱动+资源名对齐（S3）→ npu-scheduler+volcano（S4/S5）→ ARC+GitHub 凭据（S1/S20）→ 共享缓存盘+权重盘（S9/S10/S11）→ 出网三件套 squid/nginx-cache/git-cdn（S13–S16）→ SWR pull secret（S19）+ 时钟与 DNS（S23）。
2. **gitcode 系租户的可见证据只有 squid CA 分发名单**（`values-gy-001/gy-002/wlcb-001.yaml` 的 `caNamespaces`）：wlcb 有 23 个 ns、gy-001 12 个、gy-002 12 个。它们是否用 nginx 缓存/git-cdn/模型预置，本地无从判断 —— 这是新集群需求收集最大的缺口，得找对应团队各要一份 CI 定义。
3. **时间窗污点是"两侧协作"机制**：打污点在集群侧（`dedicated=night`、`752t`、`single-node`、`cache=true`、按用途独占的 `node.usage.notes`），**摘污点在业务 workflow 里定时执行**（`vllm-ascend/schedule_nightly_test_a2|a3.yaml` 的 `remove-taints` job）。新集群要同时准备：污点策略、runner+job 双侧 toleration、`npu-scheduler-nofifo`、cluster 级 `nodes` patch 凭据、`vars.A2/A3_TAINT_NODES`。
4. **模型/数据集下载是一条独立的基础设施链路**（R3+R4+S10+S17）：零卡 runner 跑 `modelscope download` → 写共享盘 → 测试侧 `HF_HUB_OFFLINE=1`/`~/models` 软链消费；云下集群 `HF_ENDPOINT=hf-mirror.com`、HK 用 `huggingface.co`；另有长跑下载 pod 用 `tc tbf` 限速（需 privileged）并容忍大模型下载专用污点；`ascend-datasync` 命名空间说明 wlcb 上还有一个**专职数据同步租户**。
5. **缓存代理有 4 个并存实例，新集群容易接错**：`cache-service.nginx-pypi-cache`（pip/apt/rust/yum/go/crates）、`squid-cache.squid:3128`、`git-cdn-service.git-cdn:8000`（github）、`smart-git-proxy`/`git-cdn-gitcode`（gitcode）、以及 gy-001/gy-002/wlcb 里**仓库外手工部署的遗留 `git-cache-github.git-cache.svc:8080`**（拨测目标就是它，改错会假告警）。
6. **业务侧硬编码内网名**：pip 的 `--trusted-host`、apt `sed` 换 8081、rust 8082、go 8084 都是 workflow 里写死的 —— 新集群如果 svc 名/端口不一致，业务仓库必须改代码，所以**命名与端口要原样复刻**。
7. **tilelang 是反例**：明确不用远端缓存、不接 cache-service，靠宿主 `runner.tool_cache` + 预装 ccache，还要求 runner 内存规格（4 卡 115 核级）。新集群若只提供 cache-service 不提供本地大盘，它会退化到裸编译。
8. **易漏装项**：`model-cache-cleanup`、`nginx-conf-drift` 全仓库**没有任何 ArgoCD Application**（脚本手工部署）；`secret-manager` 容忍 cache 污点的 inline patch 在 gy-001/gy-002/wlcb 提交后被 revert（`fc11b9de`），单 cache 节点集群的 operator 落位需现场确认。

## 待取证清单（都是本地没有的东西，不需要动集群也能推进的除外）
- 向 14–23 列各租户索取：CI 引擎类型、pip/apt/index 源、git 平台（gitcode/gitee/atomgit）、是否下载模型数据集、是否多机、runner 规格与调度器偏好 —— 拿到后把表里的 `?` 填掉。
- 登集群核对（本次按要求**未执行**，可交给他人只读执行）：现存污点全集、NPU `allocatable` 资源名、`/mnt/sfs-local` 实际 share 清单、squid/git-cdn/nginx 的真实 svc 与端口、NetworkPolicy 与 CoreDNS forward 现状、`git-cache` 遗留服务是否健在、CN4 中心出口 IP 白名单。

## 附：三种集群形态（gy-001 / gy-002 / wlcb-001）要点，纯文字

**gy-001 = "老集群既跑 CI 又当 Provider"（28 个 Application）**
- 有：ARC 0.14.2、npu-scheduler、squid（2 副本，钉 `172.16.0.37`，该节点 `cache=true` label + `cache=true:NoSchedule` 污点，cache 盘 200G/maxObject 8G）、git-cdn（同节点，SFS 200Gi RWX）、nginx-pypi-cache-new（镜像 patch 成 `modelfoundry/nginx_pypi_cache:latest`）、sfs-local-provisioner、liqo-provider（clusterID `gy001`、apiServer `101.245.109.198:5443`、podCIDR `10.0.0.0/16`、serviceCIDR `10.247.0.0/16`、reservedSubnets `172.16.0.0/24`、`networking.enabled=false`、控制面同样钉 37 节点+cache 容忍）、secret-manager、npu-exporter-ascend、prometheus-agent+KSM、zombie-runner-cleanup
- 无：vault、imagepullsecret-patch、volcano 定制、buildkitd、KEDA、LWS、Karpenter
- 业务：vllm-ascend/triton-ascend/nv-action 的 `a2b1-{1,2,4,8}`（资源名仍报 `ascend-1980`）、recipes 与 verl-omni 的 `a2b4`、cosdt-ci-test 与 opensourceways 的 `a2-{1,2,4,8}`、`amd64-cpu-2-gy001`；gitcode 租户 12 个 ns（`argo/ragsdk/op-plugin/recsdk/multimodalsdk/indexsdk/mindstudio/slime-ascend/mindspeed/megatronadaptor/mindspeed-llm`）
- 特殊：job nodeAffinity 用 `node.kubernetes.io/npu.chip.name` 选芯片；hostPath `/mnt/sfs-local/vllm-ascend-az5` 与 gy-005 同 share 名（Liqo 同名约定的样本）；`obs-cache-secret`；listener 钉 37 节点（cosdt-ci-test/opensourceways）；同一集群 git 加速三种用法并存（git-cdn / 直接 gh-proxy / 遗留 `git-cache-github:8080`）

**gy-002（`ascend-infra-guiyang-ipv6-cluster-002`，IPv6 集群）= 纯基础设施，不承载任何 runner（3 个 Application）**
- 只有 squid（2 副本，钉 `10.0.1.220`，amd64，`cache=true` label + 同名污点，依赖 ns 内已存在的 SWR pull secret）、prometheus-agent（含 mtail/registry-nginx 抓取顺序修正）、kube-state-metrics，外加根级 `secrets-manager-guiyang-002`
- 但 squid 的 CA 分发覆盖 12 个 gitcode 租户 ns（`argo/drivingsdk/fsdpturbo/megatronadaptor/memcache/memfabric-hybrid/mindspeed/mindspeed-bridge/mindspeed-llm/mindspeed-mm/visionsdk`）→ 它是这些租户的**出网代理供给方**
- 拨测 `GH_PROXY_URL` 指遗留 `git-cache-github:8080`（曾指错导致 `GitHubProxyUnreachable` 假告警）
- 启示：一个集群可以只提供 egress + 观测；此时 P0 里的 ARC/NPU/存储整段可省，但"独占 cache 节点 + pull secret + probe 目标"三件事仍要做对

**wlcb-001 = 纯 Liqo Provider（910B4/A2B4，10 个 Application）**
- 自己不建 runner：scale set 在 hk-001 建一份、pod offload 进来（`linux-aarch64-a2-1-wlcb001`；`381da996` 统一 hk-001/gy001/wlcb001 三处 vllm-ascend PVC 名，a2b4 钉 gy001）
- 节点：arm64 910B4 为主 + **唯一 x86 节点 `192.168.1.191`**（`instance-type=c7.16xlarge.2`，带 `cache=true:NoSchedule`）同时承载 Liqo 控制面 + git-cdn + 遗留 git-cache-http-server（故 git-cdn 降到 4C/8Gi）；squid 钉 `192.168.1.49`（只有 `cache=true` label、**无污点**）
- 有：liqo-provider（clusterID `wlcb001`、apiServer `1.92.221.43:5443`、reservedSubnets `192.168.1.0/24`、`defaultNodeResources huawei.com/ascend-1980: "56"` = 8 节点×8 卡 − 留 1 台）、git-cdn（upstream gh-proxy，国内集群不直连 github）、nginx-pypi-cache-new（image patch + cache toleration）、scheduler-plugins-new、npu-exporter-ascend、secret-manager、monitoring+KSM、provider-side PVC/RBAC 三套
- CA 覆盖 23 个 ns，是 gitcode 租户最集中的一台：`argo/ragsdk/op-plugin/recsdk/multimodalsdk/indexsdk/mindstudio/slime-ascend/mindspeed/megatronadaptor/mindspeed-llm/mindspeed-mm/mindspeed-bridge/mindspeed-ops/drivingsdk/fsdpturbo/openubmc/memfabric-hybrid/memcache/cann/ascend-datasync/visionsdk`
- 无：ARC、volcano、sfs-local-provisioner、zombie-runner-cleanup、vault、imagepullsecret-patch、Karpenter、LWS、buildkitd
- 反复：git-cdn 曾删（#1647）后恢复（`5dec7fce`，issue #2178"打通云上所有 A2 资源"）；nginx-conf-drift 哨兵在 wlcb 必须加 toleration（`ci-probe` 无 arm64 变体，`ca8d34eb`）
- 启示：Provider 形态最小集 = Liqo + npu-scheduler + 出网三件套 + provider 侧同名 PVC/RBAC + exporter

## 附：新集群开箱即用清单（无表格版）
- P0（缺一个都跑不起来）：驱动与资源名对齐｜npu-scheduler+volcano+queue｜ARC+GitHub 凭据｜共享缓存盘+权重盘+sfs-local｜squid/nginx-cache/git-cdn（**svc 名与端口原样复刻**）｜SWR pull secret｜NTP+DNS+apiserver 入口白名单
- P1（能跑但会红/会慢）：Karpenter 弹性污点方案｜Liqo｜vault+secret-manager｜buildkitd+KEDA+fuse｜模型数据集下载链路与预置｜OBS 凭据与远端缓存｜监控/拨测/两类清理 CronJob｜时间窗污点协作（含 cluster 级 nodes patch 与 `*_TAINT_NODES`）
- P2（特定业务才需要）：vNPU 切片｜Karmada｜Harbor/Argus/Milvus｜Ingress+Vault TLS｜DinD 特权 runner｜只读缓存试点 runner｜自建 pypi NodePort｜gitcode 侧独立 git-cdn 实例
