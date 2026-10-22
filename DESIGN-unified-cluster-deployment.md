# 统一集群部署方案（App of Apps + ApplicationSet + 共享 Chart）

> 说明：文中 `/root/...`、`/tmp/...` 为取证时的本地运维机路径；`ascend-ci-deployment` = https://github.com/opensourceways/ascend-ci-deployment

对应 issue：opensourceways/backlog#2648（云下云上服务部署实现统一部署）
本文给出**可执行的具体方案**：目录、schema、生成器、values 分层、就绪判定、发布分组、落地计划与回滚保护。
配套：`cluster-capability-matrix.md`（S/R 代号）、`RUNBOOK-new-cluster.md`（L0–L4 分层交付）。

---

## 1. 目标与判据

沿用 issue 的三条完成标准，并把它翻译成可证伪的检查：

| 完成标准 | 本方案的判据 |
|---|---|
| 新集群接入，自动部署所有依赖服务 | 新增 1 个 `catalog/clusters/<id>.yaml`（+ 可选 1 个 profile）→ CI 输出该集群将获得的完整服务实例清单；**不复制任何 Application YAML、不改 ApplicationSet 模板** |
| 新服务添加，少量修改自动部署到所有目标集群 | 已有 Chart 的服务：1 份 `services/<svc>.yaml` + 社区启用 1 行；新类型服务：再加 1 份共享 wrapper Chart（**只一份**） |
| 支持某集群的服务配置可自定义 | 差异只写在 `values/profiles/<cluster>/<svc>.yaml`；CI 断言"其他集群最终有效值无非预期变化" |

## 2. 现状量化（本仓库实测，作为基线与收益依据）

| 指标 | 实测值 | 结论 |
|---|---|---|
| Application 文件 | 515 个（908 个 Application 对象） | 全部人工维护 |
| runner `values.yaml` | 542 个，单文件 210–300 行 | 真实差异只有 labels/卡数/CPU/内存/镜像 |
| 重复 squid proxy+CA 段 | **365 份** | 应抽进 Chart 模板 |
| 重复 driver hostPath 挂载段的 configmap | **463 份** | 同上 |
| `config-for-<cluster>` overlay 目录 | 19 个 | 应变成 profile |
| 带集群后缀的 runner 目录 | 30 个 | 应由 matrix 生成 |
| gha-runner-scale-set 依赖版本分布 | 0.14.2×432、0.15.0×49、0.13.0×36、0.12.0×18 | **"一份 Chart"必须先做版本分组** |
| root Application / ApplicationSet / AppProject 定义 | **0 / 0 / 0** | 当前没有 app-of-apps，也没有自动引导 |
| ArgoCD kustomize `LoadRestrictionsRootOnly` | 跨目录 base+overlay 构建即失败（ADR-0005、nginx AGENTS.md 记录） | **不要走 kustomize 跨目录 overlay，走 Helm 多 values + 模板** |

**集群 profile 的字段集不是我拍的，是从现网抽出来的：**

- squid：39 个字段路径中只有 **11 个**跨集群不同 → `persistence.*.storageClass`（4 种：`squid-subpath-sc`/`sfsturbo-subpath-sc`/`harbor-subpath-sc`/空串）、`persistence.*.size`（2 档）、`registryProxy.cacheMaxSize`（2 种）、`secretDefinition.caBundleKey`/`caPublicKey`（prod vs 试验田）、`secretDefinition.caNamespaces`（13 种）、`squid.urlRewrite.enabled`、`nodeAffinity` 的 hostname 与 operator（`In` 钉缓存节点 / `NotIn` 排除退役节点）
- git-cdn：30 个字段路径中只有 **1 个**不同（`persistence.enabled`，sh-001/sh-002/verl-suzhou 无 SFS 关掉）
- nginx-pypi-cache：差异是四类动作 → 镜像档（`nginx_pypi_cache:latest` vs `nginx-pypi-cache:master-a13812`）、tolerations（`cache=true`）、**存储后端二态**（PVC vs hostPath + 删 PVC + `imagePullPolicy: IfNotPresent` + nodeSelector 钉节点）、额外 initContainers（sh-001 的 `patch-cache-key`）

## 3. 权威仓库归属（先决策，否则两边都会变成事实来源）

issue 被路由到 `ascend-ci-project`，而 runner/infra 配置在 `ascend-ci-deployment`。我的建议：

| 内容 | 落位 | 理由 |
|---|---|---|
| `catalog/**`（clusters/services/communities 三类声明）、`appset-*.yaml`、`root-app.yaml`、values profile | **`ascend-ci-project`**（issue 指定服务，纯配置类） | 部署"关系"是跨仓库知识，需要一个权威处 |
| 组件 Chart 本体（squid/nginx/git-cdn/liqo/volcano/ARC wrapper…）与公共 `values/base.yaml` | 保留 **`ascend-ci-deployment/manifests/`**，以 Git repo-ref 或 **SWR OCI chart**（现网 buildkitd/argus 已用 OCI helm repo）被引用 | 不搬迁 515 个文件，降低风险 |
| runner workload 的 PodTemplate ConfigMap 与 PVC/RBAC | 保留 `ascend-ci-deployment/{projects,other}` | 与业务代码同生命周期，现网约定不变 |

判定原则：**"谁引用谁"只允许单向** —— `ascend-ci-project` 引用 `ascend-ci-deployment` 的 Chart，反向禁止。
> 待确认项①：该边界需 pkking / 集群维护者认可；若倾向全部收敛到 `ascend-ci-deployment`，则本方案的目录名平移即可，结构不变。

## 4. 目录与三类声明（schema）

```
catalog/
├── clusters/<cluster>.yaml              # 集群目录：身份 + 能力 + 成员社区 + profile 引用
├── services/<service>.yaml              # 服务目录：Chart 来源与版本档、作用域、前置、就绪
├── communities/<community>.yaml         # 社区目录：启用哪些服务、runner 规格、盘与配额
└── values/
    ├── base/<service>.yaml              # 集群无关默认（= 现 manifests 里的公共段）
    └── profiles/<cluster>/<service>.yaml# 仅差异（字段来自 §2 实测清单）
argocd/
├── appset-infrastructure.yaml           # 生成 cluster-scoped 服务 Application
├── appset-runner.yaml                   # 生成 community-scoped runner/config Application
└── root-app.yaml                        # App of Apps：只管两个 ApplicationSet
```

### 4.1 `catalog/clusters/gy001.yaml`（示意，字段即 §2 抽出的差异集）

```yaml
id: gy001
argoDestinationName: ascend-infra-guiyang-cluster-001   # 必须已注册
environment: production
rolloutGroup: group-1
communities: [ascend-gha-runners, vllm-project, triton-lang, cosdt-ci-test, opensourceways,
              mindspeed, megatron-adaptor, op-plugin, cann, sdk-family]   # 成员关系只写这一处
capabilities:                                  # L0 前置能力，缺失则阻断部署
  storageClass: harbor-subpath-sc              # 或 sfsturbo-subpath-sc / squid-subpath-sc / none
  hostPathCache: false                         # true 时 nginx 走 hostPath 形态
  cacheNode: "172.16.0.37"                     # 缓存服务落点（label cache=true）
  cacheToleration: cache=true:NoSchedule
  arch: [arm64, amd64]
  npuResourceNames: [huawei.com/ascend-1980]   # 以节点 allocatable 为准
  credentialSecret: huawei-swr-image-pull-secret-model-gy
  external: {squidCaKey: prod, nginxCaches: [pypi, whl, ascendRepos, deb, yum]}
profiles:                                      # 只有偏离 base 才写
  squid:  values/profiles/gy001/squid.yaml
  nginx:  values/profiles/gy001/nginx.yaml
```

### 4.2 `catalog/services/squid.yaml`

```yaml
id: squid
scope: cluster                      # cluster = 服务+集群只生成一次
chart: {repository: oci://swr.../modelfoundry/ascend-ci/charts, name: squid-rpardini, version: 0.1.x}
versionTrack: stable                # stable | canary —— 版本分组用
namespace: squid                    # 由 Chart 自建，root app 不设 destination.namespace
preconditions:                      # 声明式前置，不满足则阻断该实例并报错，不"默认已就绪"
  - {kind: storageClass, name: "{{ .cluster.capabilities.storageClass }}", optionalWhen: "eq none"}
  - {kind: secret, name: image-pull-secret-src-model-gy, namespace: imagepullsecret-patch}
  - {kind: vaultKv, path: secrets/data/ascend/ci, keys: [squid_ca_bundle_v3_prod_pem, squid_ca_v3_prod_pem]}
  - {kind: namespace, name: "{{ item }}", for: "{{ .service.caNamespaces }}" }   # SecretDefinition 要求 ns 已存在
readiness:
  - {httpGet: "http://squid-cache.squid.svc.cluster.local:3128/…", expect: 200}
  - {probe: doctor/squid-ca-fingerprint, equals: "{{ .cluster.capabilities.external.squidCaKey }}"}
conflictPolicy: error               # 多社区对同一 cluster-scoped 服务提出不同 profile → 报错交集群维护者
```

### 4.3 `catalog/communities/vllm-project.yaml`

```yaml
id: vllm-project
services: [arc-scale-set, nginx-cache-client, git-cdn-client, squid-client, obs-cache]
sharedVolume:
  shareName: vllm-ascend-az5        # 跨集群同名约定（Liqo 按名字映射）
  mountPath: /root/.cache
weights:
  manifest: misc/model_dataset_list.json
  pools: [a2, a3, 310p, a5]
  readyBy: "2026-10-30"             # 台账字段：未 ready 则该社区离线用例不开放
runners:
  - {label: linux-aarch64-a3-8,  cards: 8, model: ascend-1980, cpu: 64, mem: 256Gi}
  - {label: linux-aarch64-a3-800t-0, cards: 0, role: controller}
queue: {name: vllm-queue, deserved: 40}
taintsTolerated: [dedicated=night, dedicated=752t, cpu-elastic]
credentials: {githubApp: ascend-ci/vllm-project, obsSecretRef: vault://secrets/data/ascend/ci}
```

## 5. 生成器设计（ApplicationSet）

**分两阶段收敛风险（采纳 issue 的"先显式名单"）：**

- 阶段 A：`list` generator，成员来自 `catalog/clusters/*.yaml`（CI 把它们转成 appset 的 `list.elements`，或直接用 git-files）。先只覆盖 PoC 的 1–2 个集群。
- 阶段 B：`git-files` generator `path: catalog/clusters/*.yaml`，新集群=加一个文件即自动生效；**仍禁止无约束笛卡尔积**，社区目标集群集合取自 `clusters[].communities` 反向索引，由 CI 生成而非模板里做乘积。

### 5.1 `appset-infrastructure.yaml`（cluster-scoped）

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: platform-infrastructure, namespace: argocd}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]        # 缺字段直接失败，不静默渲染空值
  applicationsSync: create-update                # 迁移期防误删；需按控制面版本确认可用
  preserveResourcesOnDeletion: true              # 删 appset 项不等于卸载 workload（退役走显式流程）
  generators:
    - git: {repoURL: <ascend-ci-project>, revision: HEAD,
            files: [{path: catalog/clusters/*.yaml}, {path: catalog/services/*.yaml}]}   # 由 CI 预展开为矩阵
  template:
    metadata:
      name: "{{.cluster.id}}-{{.service.id}}"     # 稳定命名：不含 hash、不含版本，见 §10 风险
      namespace: argocd
    spec:
      project: "{{.cluster.id}}"
      source:
        - {repoURL: <chart-source>, chart: "{{.service.chart.name}}", targetRevision: "{{.service.chart.version}}"}
        - {repoURL: <ascend-ci-project>, ref: values, targetRevision: HEAD}
        helm:
          releaseName: "{{.service.id}}"
          valueFiles:
            - $values/values/base/{{.service.id}}.yaml
            - $values{{.cluster.proxies.squid}}         # profile，缺省则只有一层
      destination: {name: "{{.cluster.argoDestinationName}}"}
      syncPolicy: {automated: {prune: true}, syncOptions: [CreateNamespace=true, ApplyOutOfSyncOnly=true, ServerSideApply=true]}
```

> `matrix` generator 也可（clusters × services），但服务侧要带 `scope: cluster` 过滤；本方案把过滤放在 **CI 预展开**阶段，好处是渲染前的实例清单可 review、可断言数量，坏处是多一步 CI。> 待确认项②：CI 预展开 vs ApplicationSet 原生 matrix，二选一。

### 5.2 `appset-runner.yaml`（community-scoped）

- 生成粒度：**社区 × 集群 × runner**；`name: {{community.id}}-{{cluster.id}}-{{runner.label}}`（与现网目录名保持一一可映射，便于对账）。
- Chart 来源：`ascend-ci-deployment` 新增**一份** `charts/ascend-runner` wrapper（依赖上游 `gha-runner-scale-set`，按 `versionTrack` 固定版本档），把 365 份 proxy/CA 段与 463 份 driver 挂载段抽成模板：

```yaml
# charts/ascend-runner/templates/_platform.tpl（示意）
{{- define "ascend-runner.proxyEnv" -}}
{{- if .Values.platform.squid.enabled }}
- {name: HTTP_PROXY,  value: {{ .Values.platform.squid.url | quote }}}
- {name: NO_PROXY,    value: {{ join "," (concat .Values.platform.squid.noProxyDefault .Values.platform.squid.noProxyExtra) | quote }}}
- {name: SSL_CERT_FILE, value: /etc/ca-bundle/squid-bundle.pem}
{{- end }}
{{- end -}}
```

  于是 runner 声明只剩 `catalog/communities/*.yaml` 里的 `runners:` 一行 + 集群 profile。

### 5.3 作用域与所有权规则（必须写进 schema 校验）

1. `scope: cluster` 的服务在一个集群**只允许一个 Application**；若两个社区为其声明冲突 profile → CI 报错并点名集群维护者（不靠处理顺序"最后覆盖"）。
2. `scope: community` 的服务按社区+集群生成；**删除某社区的成员关系不得影响 cluster-scoped 实例**（由 `preserveResourcesOnDeletion` + ownerReferences 交接顺序保证，见 §10）。
3. 每个 Application 只有一个 owner 入口（appset 或旧手工 YAML），禁止双管；旧入口退出必须是显式 PR。

## 6. values 分层与"list 不合并"的解法

覆盖顺序固定：**base → community → cluster → instance**（后者优先），CI 输出最终有效值与来源行。

现网约束：Helm 的 `env`/`volumes`/`tolerations` 等 list 是**整体替换**，不是合并。方案不引入合并 DSL，改为：

- **共性进模板**（`_platform.tpl` 之类），profile 里只允许出现**标量与短枚举**（storageClass、size、hostname、key 名、布尔开关）——这正好等于 §2 抽出的 11 个 squid 字段、1 个 git-cdn 字段、4 类 nginx 动作；
- 必须传 list 时（如 `caNamespaces`），约定为"完整覆盖 + 最小长度断言"，CI 检查必要元素未丢（例如 `caNamespaces` 必须包含 `.svc(squid)` 与所有已启用社区的 ns）；
- 禁止在 profile 里手写整段 values（schema `additionalProperties: false` + 字段白名单挡住）。

## 7. 前置与就绪（回应"不能只靠 sync-wave/父 app Healthy"）

- **前置（preconditions）**：`services/*.yaml` 里的声明式条目，由 CI 在 PR 阶段用**只读**方式检查（`helm template` + `kubectl --dry-run=server` + 只读 `get` 清单），不满足则**阻断该实例并给出原因**（例如 storageClass 不存在、Vault key 未录入、caNamespaces 里某 ns 尚未创建）。这与"部署成功"解耦：Application 可以存在但标记 blocked，不伪装 Synced。
- **就绪（readiness）**：每个服务定义 1–2 条可执行探测（DNS+端口+证书指纹+CRD 存在），由 `doctor` 作业与公共冒烟执行（见 `RUNBOOK-new-cluster.md` §3 的 6 条冒烟、§9 的 10 项体检）。
- **顺序**：appset 生成顺序 ≠ 依赖顺序。真正的顺序由 preconditions 卡住；模板里保留 sync-wave 只用于同 app 内资源，不作为跨 app 就绪依据。

## 8. 版本分组与发布策略

- `rolloutGroup: canary → group-1 → group-2 → legacy`；`services[].versionTrack` 决定组内版本档。
- 依据实测版本碎片（0.14.2×432 / 0.15.0×49 / 0.13.0×36 / 0.12.0×18）：**先建版本档映射表**（哪档对应哪个 track），共享 Chart 一次只升一档，不一次升全员。
- 公共 `values/base` 或 Chart 模板的改动：CI 必须列出受影响实例矩阵 → 只同步 canary → 观察 ≥24h → 按组放量。gy-006 作为试验田沿用现网 SOP（先 3 天再推广）。

## 9. CI 必须输出（每次 catalog PR）

1. schema/引用校验、命名唯一性、scope 冲突、禁止未注册 destination、禁止明文 Secret。
2. **实例矩阵预览**：新增/变更/删除的 `社区 × 服务 × 集群` 清单，带 rolloutGroup 与最终有效 profile 来源。
3. 渲染 diff（与 parity 基线比对，见 P0）+ 关键字段保护检查（proxy env 数量、CA 挂载、driver hostPath、toleration、`releaseName`）。
4. preconditions 检查结果（哪个实例被阻断、原因、需要谁准备）。
5. 门禁状态：本批是否放行、下一批被什么挡住。
6. 与现网门禁共存：继续跑 `argocd-app-lint.sh`、`check-projects-coverage.py`（RA/RC）、`squid-injection.py audit`（退化为审计）、`tests/` 断言、`nginx-conf-drift`。

## 10. 落地计划（P0–P4）

| 阶段 | 动作 | 样本 | 验收 | 回滚 |
|---|---|---|---|---|
| **P0 基线**（1 周，我补的步骤） | 定仓库边界（待确认①）；写 3 份 schema；把现网 515 个 Application **离线渲染成 parity 基线快照**；建版本档映射表 | 无变更 | 基线可复现；schema 能表达 squid 的 11 个差异字段、git-cdn 的 1 个、nginx 的 4 类动作 | 纯文档，git 回退 |
| **P1 等价迁移**（issue 原样） | 只换 Chart 来源，保留完整 values 与 app 名/releaseName/ns | gy-006 三个样本：`ascend-gha-runners` amd64-cpu-2、a2 单卡、`nv-action` cpu-4（均为 ARC 0.15.0） | 0 未批准语义差异；无核心资源 delete/recreate；真实 CPU/NPU job、扩缩容、回滚通过；3 份 wrapper 收敛为 1 份 | 保留旧 Chart 作回滚点；恢复旧 source |
| **P2 声明驱动 + root** | 把 P1 样本纳入 catalog，由 appset 生成**同名** Application；root 管 appset；抽取明确共性 values | 同上 + 1 个非关键 cluster-scoped 服务 | 新增同类 runner 只需 profile + 清单项；单实例覆盖不影响他人；旧入口退出后仅 1 个 owner | `applicationsSync: create-update` 期间不删资源；交还旧入口用非级联方式 |
| **P2.5 infra 类样本**（我补） | 选**低风险、无状态、可回滚**的 infra 进 appset | 建议 `zombie-runner-cleanup` 或 monitoring overlay（**不碰 squid/nginx/git-cdn**） | preconditions + readiness 真实拦到一次"缺前置"场景（例如 vault key 缺失） | 停用 appset 项、恢复手工 YAML |
| **P3 跨集群闭环** | 离线断言（新集群/新服务/覆盖/隔离）→ 获授权后加**第二个真实测试集群**，仅加成员关系 | gy-006 + 第二集群 | 第二集群自动获得该社区全部已声明依赖且不落到无关集群；新增一个服务清单项覆盖该社区现有集群；给一个集群加 profile 只影响它。**两个 ns 不算两集群**；第二集群不可用则 P3 标 blocked，不得据此关 issue | 集群退组 + 保留资源（不自动 prune workload） |
| **P4 推广与收敛** | 逐社区/逐类服务迁移（无状态优先→特殊 runner→有状态/关键依赖）；每类首个样本过再批量；**生产推广需单独审批**；最后删除无消费者的重复 Chart/Application，更新目录规范与测试 | 全量 | 未参与者按文档独立完成"新增标准集群声明 / 启用已有服务 / 添加单集群差异"三件事，记录改动文件数且**无需改模板** | 按服务粒度回退；旧结构删除放在最后且单独 PR |

## 11. 上线保护（迁移期硬规则）

1. **Application 名必须稳定**：`nameTemplate` 不用 hash、不加版本。名字变化 = app 重建 = **ARC 在 GitHub 重新注册 runner，在跑/排队 job 变孤儿**（现网事故型风险）。
2. 每次只交接**一个服务实例**；切换前排空该 scale set 在跑任务，固定 Git SHA，再切 owner。
3. 交接顺序写死：新 appset 建同名 app → 观察 Synced/Healthy → 旧 YAML 在**同一 PR** 删除并记录 → 禁止靠父 app 自动 prune 删旧 app。
4. 评估并实测 `applicationsSync: create-update` 与 `preserveResourcesOnDeletion: true` 在当前控制面版本真的生效；用独立 canary 演练"删清单/orphan"行为，不假设"删父对象永远安全"。
5. 回滚优先"停上游回写 → 恢复旧 source/values 或非级联交还旧入口"，用 Git 回退；**不删 namespace、不卸 controller**。
6. 同名资源不得被两个 Application 管理（防 tracking-id 抢占与 sync-prune 互抢，现网 vllm-omni 已踩）。

## 12. 收益预估（可核对）

- 新集群接入：从"抄 20–30 个 Application + 每业务 1 个 config overlay" → **1 个 `clusters/<id>.yaml`（+ 按需 profile）**。
- squid 维护：13 份 values → 1 份 base + 11 个字段的 profile 集合；git-cdn：15 份 → 1 份 base + 1 个布尔；nginx：4 类动作变成 2 个开关（`hostPathCache`、镜像档）。
- proxy/CA 与 driver 挂载：365 + 463 份重复段 → Chart 模板 1 份；`squid-injection.py` 从"批量改写工具"降级为"审计工具"。
- 新增 runner：从"新目录 + 300 行 values + Application" → `runners:` 1 行。

## 13. 未决与风险

- 待确认①：catalog/root/appset 的权威仓库（`ascend-ci-project` vs `ascend-ci-deployment`）。
- 待确认②：实例矩阵由 CI 预展开还是 ApplicationSet 原生 matrix。
- 待确认③（来自 issue）：控制面 ArgoCD 版本与 ApplicationSet controller 是否启用、`applicationsSync`/`preserveResourcesOnDeletion` 支持情况。已知 sh-001 为 ArgoCD v3.5.1；中心控制面版本待核。
- 风险 A：**爆炸半径放大** —— 一处 profile 或 Chart 改动可触达全集群。对策：rolloutGroup + canary 强制、PR 必须展示受影响矩阵、公共改动禁止单步全量。
- 风险 B：**渲染压力** —— 现网已 908 个 Application，matrix 化后数量与 repo-server 渲染负载上升。对策：分批放量、保留 `ApplyOutOfSyncOnly`/SSA、必要时按服务组分多个 appset。
- 风险 C：**"社区"定义要覆盖 gitcode/内部租户** —— mindspeed 系、megatron-adaptor、op-plugin、cann、fsdpturbo、memfabric/memcache、六个 SDK + mindstudio、slime-ascend、openubmc、ascend-datasync、argo 只在 gy-001/gy-002/wlcb-001，且诉求未知。若 catalog 只给 GitHub 侧留位置，完成标准 1 在这三台必然失败。对策：先给它们建 `communities/*.yaml` 占位（`services: [squid-client]` + `status: 待取证`），CI 允许"已知未就绪"状态存在。
- 风险 D：cluster-scoped 服务的 profile 冲突在现网已事实存在（gy-001/wlcb 用 `nginx_pypi_cache:latest`、sh 系用 hostPath、gy-006 用 prod 之外的 CA key），`conflictPolicy: error` 上线前必须先做一次冲突清单收敛。

## 14. 需要 review 的具体问题

1. 仓库边界（待确认①）——若认可，我把 schema 与 appset 骨架起草到 `ascend-ci-project` 分支。
2. P2.5 选哪个 infra 样本（我建议 `zombie-runner-cleanup`：无状态、单 ns、失败可即时回退）。
3. `conflictPolicy: error` 是否接受"配置冲突阻塞部署"的产品语义（vs 允许人工最后覆盖）。
4. 版本档映射表的归属（谁维护 4 个 ARC chart 版本的 track 划分）。

---

### 附：字段抽取与验证方法（可复现）

- Application 聚合：`tools/scan_argocd_apps.py`（本仓库，只读解析 `argocd/**`）。
- 跨集群差异字段：对 `argocd/clusters/squid-rpardini/values-*.yaml` 做 YAML 叶子路径展开，统计"取值集合大小 > 1"的路径 → 得到 §2 的 11 个字段。同法用于 git-cdn（解析 Application 内 `helm.valuesObject`）与 nginx（解析 `kustomize.patches`）。
- 迁移前请以此法重跑一次，作为 parity 基线的输入之一。
