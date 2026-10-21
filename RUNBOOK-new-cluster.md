# 新集群接入 Runbook（从零到"任务进去就能跑"）

配套：`cluster-capability-matrix.md`（服务/诉求总表 + 依赖关系列）。
文中 `/root/...` 为取证时的本地运维机路径；`ascend-ci-deployment` = https://github.com/opensourceways/ascend-ci-deployment 。
**约束**：本 runbook 的编写全程只读；所有需要登集群的动作只写步骤与只读验收命令，由有权限的人执行。

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
