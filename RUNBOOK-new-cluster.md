# 新集群接入 Runbook

配套：`cluster-capability-matrix.md`（总表 + 速查表）。本文用的 `S*` / `R*` 代号与速查表一致。
编写全程只读；所有需要登集群的动作只给步骤和**只读**验收命令，由有权限的人执行。

## 0. 怎么用这份文档

- 一条主线：**L0 底座 → L1 公共服务 → L2 社区接入 → L3 项目接入 → L4 运营**，一层一层过，每层有"出门条件"，不满足不进下一层。
- 一条原则：**L1 不区分社区**（装完全集群共用）；**社区差异只落在 L2**（盘、权重、配额、卡池）；**仓库差异只落在 L3**（runner、凭据、代理注入）。
- 一条纪律：外部资源（ELB、SFS、白名单、Vault 内容、Harbor 账号）是**日历时间**，在 L0 之前就要发起申请，不要等到要用了再提。

## 1. 全流程一览

| 层 | 目标 | 出门条件（全绿才进下一层） | 谁负责 |
|---|---|---|---|
| L0 底座 | 节点能调度、时间对、域名解析对、出入口通 | 节点全 Ready；`date -u` 正确；NPU 资源名确定；出网/入网白名单生效 | 运维 + 云 |
| L1 公共服务 | 代理、包缓存、git 加速、调度栈、控制器就位（不分社区） | 第 3 节的 6 条公共冒烟全过 | 平台 |
| L2 社区接入 | 该社区的盘、权重、配额、卡池就绪 | 台账该行"权重就绪 = 是" + 抽查目录命中 | 平台 + 社区 |
| L3 项目接入 | 该 org/repo 的 runner、RBAC、凭据、代理注入就绪 | RA/RC 门禁通过 + 该仓库冒烟绿 | 项目 + 平台 |
| L4 运营 | 持续：时间窗、发布、清理、告警、台账维护 | 值班与告警接上，无失明 | 平台 |

---

## 2. L0 底座

**输入**：机型清单（arch、NPU 型号与卡数）、OS、云与 region、期望 CNI、apiserver 入口（内网 + 公网 ELB）、存储类型（SFS / NFS / hostPath / harbor-sc）。

**步骤**

1. 申请外部资源：SFS/EVS 盘与 share-id、ELB/EIP、安全组端口（10250、CNI 4240/8472、NodePort 段）、NGFW 域名放行、中心监控放行 `113.44.182.82:9090/9091`。
2. 节点装机：昇腾驱动 + Docker Runtime（ADR）+ Device Plugin，**版本必须配套**。
3. containerd：v1.6 用 config.toml 老式 mirrors，v2.x 用 `certs.d/hosts.toml`；**改完重启 containerd**。
4. OS 适配：openEuler 无 systemd-resolved → 建 `/run/systemd/resolve/resolv.conf` 软链。
5. 时钟：chrony；UDP123 被封则装 HTTP-Date 兜底 timer。
6. 镜像预缓存：pause、CNI、runner、busybox（走 `ctr images import`）。
7. 网络：按拓扑选 CNI 模式（VPN/多网卡不要硬上 native routing）；Cilium 关 kube-proxyReplacement 时补 SNAT。
8. apiserver 入口：ELB 绑定 + `certSANs` 覆盖**全部**入口 IP（所有 master 的管理面/服务面 IP + 两个 ELB IP）。
9. 存储目录：按 share 名准备导出，并挂/bind 成 `/mnt/sfs-local/<share>`；NFS 子目录要预导出并 chmod。
10. 缓存节点（若沿用单点模式）：打 `cache=true` label（污点按集群决定）。

**只读验收**

```bash
kubectl get nodes                                     # 全 Ready，无 NotReady
kubectl get node -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.osImage
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable}{"\n"}{end}'   # NPU 资源名以这里为准
kubectl get cm coredns -n kube-system -o yaml | sed -n '/forward/,/}/p'
date -u                                               # 每台节点都对
```

**常见失败**：`dcmi init failed -8255`（ADR/DCMI 版本不配套）｜pod sandbox 创建失败（resolv 软链缺失）｜apiserver 全部 CrashLoop（重签证书没合并旧 SAN）｜新节点镜像拉不到（没预缓存 + DNS 顺序错）。

---

## 3. L1 公共服务层（不区分社区）

**输入**：storageClass 名、cache 节点 hostname、squid CA 的 Vault key、是否要 Liqo/Karpenter/buildkitd。

**安装顺序（依赖决定，不可乱序）**

| 序 | 装什么 | 关键约束 | 验收 |
|---|---|---|---|
| 1 | S19 SWR pull secret | 名字必须是 `huawei-swr-image-pull-secret-model-gy`，下游全硬引用 | 任一 ns 里 `kubectl get secret` 可见 |
| 2 | S20 vault / secret-manager | Vault 侧 KV 内容先有；AppRole Secret 预建 | SecretDefinition 能生成 Secret |
| 3 | S13 squid | 独占 cache 节点；`caNamespaces` 里的 ns 必须已存在；CA 指纹要与客户端一致 | 集群内 `curl -x squid-cache.squid:3128 https://pypi.org` 200 |
| 4 | S14 nginx-pypi-cache | svc 名与端口原样复刻；容量按本集群核定；hostPath 形态要同删 PVC | `curl cache-service.../pypi/simple/` 有 `X-Cache` |
| 5 | S16 gh-proxy 可达性 → S15 git-cdn | git-cdn **必须单副本**；SFS 用 RWX，无 SFS 就关持久化 | `git ls-remote` 经 `:8000` 前缀成功 |
| 6 | S11 sfs-local-provisioner + storageClass | 必须带 `cceaddon-volcano` 豁免标签；排除 liqo 虚拟节点 | 节点上 `ls /mnt/sfs-local/` 见 share 目录 |
| 7 | S3 设备 + S4 npu-scheduler + S5 volcano + Queue + S6 LWS | **LWS 现网只有 gy-003 有清单**，要多机就得显式补装 | `kubectl api-resources | grep -i leaderworkerset` |
| 8 | S7 Liqo（如需） | 两侧 `networking.enabled` 一致；provider 侧 app 不要 `CreateNamespace=true` | 虚拟节点出现且 `curl` apiServer 返 401 |
| 9 | S8 Karpenter NodePool（如需） | **先给 runner 加 toleration，再给 NodePool 加污点** | NodePool Ready，弹性节点带污点 |
| 10 | S1 ARC controller | 镜像架构匹配（0.14.201 仅 amd64） | `kubectl get pods -n arc-systems` |
| 11 | S21 buildkitd（如需） | 依赖 S20 证书 + S13 CA 分发到 buildkitd ns + `devic.es/fuse` + 节点 seccomp profile | `buildctl debug workers` 有节点 |
| 12 | S22 观测与清理组件 | node-exporter 用静态 IP 列表；被 NGFW 挡则装 pushgateway-local（**必须 v1.10.x**）；**补装 `model-cache-cleanup`、`nginx-conf-drift`（现网无 GitOps 清单）** | 中心 Prometheus 能查到该集群 up=1 |

**公共冒烟（6 条，与任何社区无关）**

1. 临时 pod 走 squid 访问公网 + 校验 CA（`SSL_CERT_FILE` 指向合并 bundle 后 `curl https://pypi.org` 不报证书错）。
2. `pip install -i http://cache-service.nginx-pypi-cache.svc.cluster.local/pypi/simple --trusted-host <同域>` 成功且命中缓存。
3. `git clone https://github.com/<公开仓>` 经 git-cdn insteadOf 成功，不出现 TLS 超时断连。
4. `buildctl build` 出一个 hello 镜像并推到 SWR。
5. 申请 1 张 NPU 的 pod 能 Pending→Running，容器内 `npu-smi info` 有输出。
6. 中心能看到该集群指标与拨测数据（无 ProbeStale）。

**常见失败**：squid CA 用了另一套 key（试验田 vs prod）→ 全链路 TLS 失败；改 nginx conf 没更新 `checksum/nginx-conf` → pod 不滚动、配置不生效；多副本 git-cdn/smart-git-proxy → packfile 与 refs 损坏；cordon 被自动解除导致服务落回退役节点（要用 nodeAffinity NotIn）。

---

## 4. L2 社区接入层（每社区一次）

**输入**：社区要哪些集群、卡数与规格、需要哪些模型/数据集、是否需要独立卡池。

**步骤**

1. 建社区 ns + `runner-pod-permission`（SA + Role：pods/pods-exec/pods-log/jobs/secrets，**同 ns 多社区时不要重复声明 ns/RBAC**，会被两个 Application sync-prune 互抢）。
2. 建共享缓存盘：PVC 或 hostPath `/mnt/sfs-local/<share>`；**share 名沿用跨集群同名约定**（Liqo 按名字映射，名字错位 = offload pod 永久卡死）。
3. 权重/数据集同步：用零卡 runner（`*-0`）跑清单下载，或 `sync-tools` 跨集群复制；云下 `HF_ENDPOINT=hf-mirror.com`，HK 直连 huggingface；大文件下载可另起长跑 pod 并用 `tc` 限速（需 privileged）。
4. Queue 配额：capability / deserved 按社区谈定（deserved 就是预留卡数）。
5. 卡池归属：是否需要 `dedicated=night`、`752t`、`single-node` 等污点池，以及谁在什么时间打/摘。
6. **登记台账**（下表）：社区、集群、盘名、权重是否就绪、确认人。
7. 把社区 ns 追加进 squid 的 `caNamespaces`（ns 必须已存在，否则 SecretDefinition 报错）。

**出门条件**：台账该行"权重就绪 = 是"；抽查 `ls /root/.cache/modelscope/hub/models` 或 `ls /root/.cache/huggingface/hub` 命中；否则该社区的离线类用例不开放。

**常见失败**：只读试点 runner 只挂 `huggingface/`、`modelscope/` 子目录，盘上目录结构不对就整片失败；NFS 上 `fcntl.flock` 不互斥，多 pod 并发写缓存有风险；SFS 的 `everest.io/reclaim-policy` 注解实测不生效，PV 落 Delete，**部署后要手工 patch Retain**。

**社区层接入台账**（现网已取证，新集群照此续填）

| 社区 | 集群 | 共享盘 / 权重通道 | 权重就绪 | 状态 |
|---|---|---|---|---|
| vllm-project（vllm-ascend、vllm-omni、nv-action fork） | gy-001/005、hk-001、cn12、sh-001、gy-003/006 | `vllm-ascend-az5`、`gy005-az5-vllm-ascend-v2`、`vllm-project-hk001`、`nv-action-vllm-benchmarks-v2/-v3`、`/mnt/weight`、`/mnt/share` | 是（清单 `misc/model_dataset_list.json` 驱动，a2/a3/310p/a5 分池） | 已登记；大盘被 5+ 社区共用 |
| sgl-project（sglang、sglang-omni、sgl-kernel-npu）+ Ascend/sglang | hk-001、cn12、gy-004、sh-002 | `sgl-project-sglang-v2/-v3`、`sglang-guiyang004`、`ascend-ci-share-pkking-sglang`、`...-liqo-v2`、`/data` | 是（用例硬编码 modelscope 绝对路径） | 已登记；sh-002 走自建 NFS |
| volcengine（verl、uni-agent、verl-SpeCo、verl-omni） | hk-001、mind-third-ci、verl-suzhou、cn12、gy-001 | `hk001-v1`、`verl-hb003`、`verl-project-liqo-cn12-001-v2`、`/nfs/verl_ci` | 是（含只读试点 runner） | 已登记；三集群同名 hostPath 约定 |
| Ascend（pytorch、sglang、cann-container-image、docs、ray-ascend） | cn12、aiframework、gy-005、sh-002、gy-001、hk-001 | `ascend-ci-share-pkking-pytorch`、`ascend-pytorch-share-pvc`、`ascend-cann-container-image`；产物走 `obs://pytorch-ci-cache` | 是 | 已登记 |
| triton-lang（+ 个人 fork） | cn12、hk-001、gy-001、gy-005、sh-002 | `ascend-triton-ascend-gy005/hk001`、`triton-ascend-cn12-001-pvc` | 是（大文件走 OBS 非权重盘） | 已登记 |
| tile-ai（tilelang、mlir-ascend） | sh-002、cn12 | `tile-ai-tilelang-share-pvc`、自建 NFS、`tile-ai-tilelang-ascend-gy005` | 不适用（不用远端缓存，依赖宿主 tool_cache + ccache） | 已登记；新集群必须给本地大盘 |
| alibaba/ROLL、areal/AReaL | cn12 | `alibaba-roll-cn12-001`、`...-liqo-cn12-001-v2`、`areal-project-areal-shared-v3` | 是 | 已登记 |
| HK a2 系（fla-org、hiyouga、modelscope、pt-ecosystem、UsernameFull） | hk-001 | `hk001-v1`（多社区共用整盘）、`fla-org-...-a2-hk-001` | 是 | 已登记；同盘并发写有 flock 风险 |
| 平台/组织级（ascend-gha-runners、cosdt、GanDing、opensourceways、agentic） | 13+ 集群 | `ascend-ci-share-ascend-gha-runners`、`ascend-gha-runners-gy001`、`cosdt-ci-test-gy001`、`opensourceways-gy001`、gy-006 静态 PV | 部分 | 已登记；`sync-tools` 是同步执行者 |
| gitcode / 内部租户（mindspeed 系、megatron、op-plugin、cann、fsdpturbo、memfabric/memcache、六个 SDK + mindstudio、slime-ascend、openubmc、ascend-datasync、argo） | gy-001、gy-002、wlcb-001 | 待登记 | 待登记 | **缺口**：集群侧只能证明它们拿到 squid CA；从 wlcb 的 `ascend-datasync` 要台账最快 |

---

## 5. L3 项目接入层（每 org/repo）

**步骤**

1. `projects/<org>/<repo>/config-for-<cluster>/`：PodTemplate ConfigMap、PVC、`github-app-secret.yaml` 或 `github-token-secret.yaml`。
2. `linux-<arch>-<npu>-<n>-<cluster>/values.yaml`：runner scale set；ARC ≥0.14 必须两个 `scaleSetLabels`；标签与 `runs-on` 严格一致。
3. 登记 runner 标签到手册（`check-projects-coverage.py` 的 RA/RC 会拦未登记与无 app 的目录）。
4. `scripts/squid-injection.py inject <runner_dir>`：同时注入 `values.yaml` 与 job PodTemplate（只注入前者 = job 仍直连），再跑 `check`。
5. git insteadOf（git-cdn 或 gh-proxy，按该集群实际有的代理）、`OBS` 凭据（`obs-cache-secret`）、需要的 `huawei.com/schedule_policy` 注解。
6. GitHub 仓库侧 secrets/vars：`KUBECONFIG_*_B64`、`A2/A3_TAINT_NODES`、`SWR_USERNAME/PASSWORD`、`OBS_*`/`HW_OBS_*`、`QUAY_*`、`PAT_TOKEN`、`NIGHTLY_COMMAND_BLOCK_WINDOW`。
7. `argocd/clusters/<cluster>/` 建 config + runner Application，等同步绿。
8. 冒烟：按业务挑适用子集（CPU lint / 单卡 NPU / 多机 / 走代理的构建 / 离线权重加载）。

**出门条件**：RA/RC 通过 + 冒烟绿 + 中心无该 ns 的 Pending/CrashLoop 告警。

**常见失败**：手动 `kubectl patch` 的字段（如 `maxRunners=0`）不在 values 里，重部署即丢失；helm uninstall 重装会让 GitHub 注册新 runner ID、旧 job 变孤儿（改配置只能 upgrade）。

---

## 6. L4 运营层（持续）

- 时间窗：夜间/整机池按约定打污点与摘除；摘污点现网由业务 workflow 执行（`kubectl taint nodes $A2/A3_TAINT_NODES dedicated-`），打污点在集群侧 —— **归属必须写在集群文档里，不能靠口口相传**。
- 发布：缓存/代理组件走 `nginx-cache-rollout-gate.py`（fail-closed：查不到状态就不放行）；新逻辑先进 gy-006 试验田观察 ≥3 天。
- 清理：僵尸 runner（15 分钟一次，保留 `--wait=false`）、模型缓存（周二 19:00，atime 90 天规则）。
- 告警：新集群必须在中心有拨测与规则；注意 `severity: warning` 是黑洞、拨测类要配 `ProbeStale` 兜底。
- 台账：新社区接入即追加一行，权重就绪状态由社区负责人签字确认。

---

## 7. 决策点（18 项，标好该在哪一层拍板）

| 层 | 决策点 |
|---|---|
| L0 | ① CNI 模式（tunnel/native）② 存储方案与 share 命名（是否沿用同名约定）③ NPU 资源名口径（以 allocatable 实测为准）④ 驱动/ADR/DCMI/Device Plugin 版本矩阵 |
| L1 | ⑤ squid registry 与 urlRewrite 白名单 ⑥ squid CA 用 prod 还是试验田 key ⑦ nginx 容量 `max_size`（每集群核定）⑧ 是否装 LWS（多机路线：LWS vs RayJob）⑨ ARC 版本与镜像架构（arm-only 不能用 0.14.201）⑩ 出网/入网白名单范围（NGFW 域名、中心放行 IP） |
| L2 | ⑪ 承载社区清单（总表 23 列勾选）⑫ Queue capability/deserved 配额 ⑬ 是否给独立卡池与时间窗归属 ⑭ 是否支持 legacy 业务（`imagePullPolicy: Never` → 节点预缓存） |
| L3 | ⑮ Vault KV 内容由谁录入、GitHub App 授权范围 ⑯ 仓库 secrets/vars 由谁下发 |
| L4 | ⑰ 发布窗口批准权 ⑱ 放行标准（冒烟 5 条是否作为上线门槛） |

## 8. 自动化清单（41 项，按层归位）

| 层 | 已现成 | 需新写 | 半自动（云 API/工单） | 纯人工 |
|---|---|---|---|---|
| L0 | `resource-deploy-core`（节点探测/join/软件下发/TTL 清理）；现网装机模板 | 装机 playbook（containerd 双格式、resolv 软链、时钟兜底、镜像预缓存清单固化） | ELB/EIP+certSANs、安全组、NGFW 放行、中心监控放行、SFS/EVS 建盘、NFS 预导出+chmod、驱动与 device plugin 装机、节点 label/taint 初始化 | 版本矩阵确认 |
| L1 | helm+kustomize 的 22 项 infra、`argocd-app-lint.sh`、`tests/` 断言、`nginx-conf-drift`、GitOps 同步 | `cluster.yaml` schema+校验、ApplicationSet/root-app 生成器、每集群 values 渲染、sync-wave 编排、`new-cluster-doctor.py`、公共冒烟脚本、`model-cache-cleanup`/`nginx-conf-drift` 补 GitOps | Harbor/SWR 命名空间与机器人账号、Liqo 两侧 peer 与可达性验证、集群注册进 ArgoCD、Vault 服务端 policy/role | CA/registry 白名单拍板、nginx 容量核定 |
| L2 | `sync-tools` runner、`install-docker-cli` 预热 Job 模式、`check-projects-coverage.py` | 台账登记工具（表 → Git）、权重就绪抽查脚本 | 权重重下载/跨集群同步、只读子目录核对 | 配额谈判、卡池归属 |
| L3 | `squid-injection.py`（audit/inject/revert/check）、RA/RC 门禁 | GitHub secrets/vars 批量下发、Vault 写入脚本、Obs/凭据模板生成 | — | 授权范围决定 |
| L4 | `nginx-cache-rollout-gate.py`、zombie-runner-cleanup | 时间窗自动打/摘污点控制器（可写，但要先定归属） | — | 发布批准、验收签字 |

**投入产出**：先做 L1 的 `cluster.yaml` schema + ApplicationSet + doctor + 冒烟脚本 + secrets 下发这 5 件，手工动作可从约 40 次降到约 8 次；剩下的瓶颈是 14 个云 API/工单类动作，属日历时间，写脚本也不会变快。

## 9. 只读体检（doctor）项

按顺序核对，任一不过就回到对应层：

1. 节点 Ready、arch/OS 正确、`date -u` 一致
2. `allocatable` 的 NPU 资源名 = 业务 requests 用名
3. 污点全集 = 集群文档约定（`dedicated`、`cache`、`single-node`、`cpu-elastic`、`node.usage.notes`）
4. `kubectl get sc` 与 `/mnt/sfs-local/` 实际 share 清单齐全（跨集群同名的都对上）
5. squid / nginx / git-cdn / buildkitd 的 svc 与端口可达，且 CA 指纹与客户端一致
6. 拨测 `GH_PROXY_URL` 指向的是业务**实际在用**的代理（gy-001/wlcb 教训：探的是遗留 `git-cache-github:8080`）
7. NetworkPolicy 与 CoreDNS forward 现状符合预期（现网多数集群靠安全组，无 NetworkPolicy）
8. 清理类 CronJob 存在：`zombie-runner-cleanup`、`model-cache-cleanup`、`nginx-conf-drift`
9. 中心能查到该集群指标（无 ProbeStale / 无上报失明）
10. GitHub 仓库侧 secrets/vars 齐全，runner 标签已在手册登记
