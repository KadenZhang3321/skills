---
name: ci-deployment-appofapps
description: Use when planning or executing the migration of opensourceways/ascend-ci-deployment ArgoCD Applications to an app-of-apps/ApplicationSet model. Covers inventory, platform-service catalog, runner-project catalog, cluster-values leaves, hub bootstrap, migration waves, parity checks, rollback, and CI gates.
---

# ci-deployment App-of-Apps 改造方案

> 适用仓库：
>
> - `opensourceways/ascend-ci-deployment`：生产集群（arc-prod、hk-001、cn12、gy-*、sh-* 等）
> - `opensourceways/arc-fedsched`：test-01/02/03 等测试集群
>
> 盘点时间：2026-11-09。数字会变，执行前先重新跑 inventory。
>
> 核心原则：**迁移只改 ArgoCD Application 的归属和生成方式，不改 workload 的期望态。**
> 任何会导致 Pod/DS/Deployment 重启的改动，都必须单独拆出来、单独验证。

## 0. 仓库边界（硬约束）

test 和 prod 不混在同一个仓库：

| 环境 | 仓库 | 内容 |
|---|---|---|
| test-01/02/03 | `arc-fedsched` | test 的 appset、cluster-values、projects、bootstrap root |
| 生产 | `ascend-ci-deployment` | 生产的 appset、cluster-values、projects、bootstrap root |

两个仓库共用同一个 hub，但：

- appset 对象名必须全局唯一：test 用服务名或 `test-` 前缀，生产统一 `arc-prod-` 前缀
- 两个独立的 bootstrap root：
  - `root-appsets-test` → `arc-fedsched/argocd/appsets`
  - `root-appsets-prod` → `ascend-ci-deployment/argocd/appsets`
- 本文档第 2 节的 33 个集群、1,014 个 Application 是 **ci-deployment 生产仓库**的盘点；test 仓库单独盘点，不要混算。
- 不要为了“统一”把 test appset 放进 ci-deployment，也不要把生产 appset 放进 arc-fedsched。

## 1. 结论

不要给 1,014 个 Application 建 1,014 个 appset。按三类对象拆：

| 类型 | 例子 | 目标模型 |
|---|---|---|
| A. 平台服务 | git-cdn、nginx-pypi-cache、imagepullsecret-patch、secrets-manager、sfs、squid、nfs-storage、npu-exporter、npu-scheduler、Liqo | **一个服务一个 ApplicationSet** + 每集群一个 cluster-values |
| B. Runner/项目 | ARC scale set、listener、runner config、RBAC、PodTemplate | **一个项目一个 values 文件 + 一个共享 chart**，chart 内 `range` 生成所有 runner/listener |
| C. 集群单例/厂商组件 | dashboard、buildkit、karmada、监控 agent、特殊 controller | 先保留为 cluster 目录叶子，最后一批迁移或明确例外 |
| D. ARC 控制面 | arc-controller | 最后单独审批；不和平台服务混批 |

最终形态：

```
Hub ArgoCD
├── root-appsets-test                # arc-fedsched/argocd/appsets
│   └── test ApplicationSets
└── root-appsets-prod                # ascend-ci-deployment/argocd/appsets
    └── ApplicationSets
        ├── platform/git-cdn
        ├── platform/nginx-pypi-cache
        ├── ...
        └── projects/ascend-ascend-ci
            └── generated Applications per cluster
```

加上两层叶子：

- **平台服务**：`argocd/cluster-values/<cluster>.yaml`
- **Runner 项目**：`argocd/projects-values/<project>.yaml`

新增集群 = 注册集群 + 1 个 AppProject + 1 个 cluster-values + group 标签。
新增平台服务 = 1 个 appset 文件。
新增 runner 项目 = 1 个项目 values 文件 + 1 个 appset entry（或一个项目 appset）。

## 2. 现状盘点

截至 2026-11-09：

| 指标 | 数量 |
|---|---:|
| `argocd/clusters/` 下集群目录 | 33 |
| `argocd/clusters/` 下 Application 文档 | 1,014 |
| 顶层多集群共用 YAML 文件 | 6 |
| `argocd/appsets/arc-prod-*` | 14（13 个服务 + pilot） |
| `argocd/projects/` 文件 | 1（`cluster-roots-prod`） |

主要问题：

1. **N×M 文件**：33 个集群目录，平台服务和 runner 都按集群复制。
2. **手工 apply**：多集群文件里的 Application 需要人工或流水线逐个 apply 到 hub。
3. **命名冲突**：test 和 prod 共用 hub，同名 appset/Application 会互相覆盖。
4. **集群接入不统一**：没有“加一个文件就补齐所有服务”的入口。
5. **Runner 文件爆炸**：PR #2382 一个项目 21 个文件，其中 4 套 runner values 和 4 个 ConfigMap 高度重复。
6. **漂移与既有异常混在一起**：squid/sfs/secrets-manager 等本来就有 OutOfSync/Progressing，迁移时必须和既有问题隔离。

## 3. 目标架构

### 3.1 三层

```
L0  root-appsets-test / root-appsets-prod（每个仓库一个 hub bootstrap，一次 apply）
L1  ApplicationSet catalog（平台服务 / runner 项目）
L2  cluster-values / project-values（叶子，只写差异）
L3  ArgoCD 生成的 Application → workload
```

- **L0** 是一个普通 ArgoCD Application，source 指向 `argocd/appsets/`，只负责把 appset 对象 apply 到 hub。它不直接管 workload。
- **L1** 每个 appset 是一个“服务 root”或“项目 root”。
- **L2** 一个集群一个文件；一个项目一个文件。
- **L3** appset controller 生成 Application；Application 自己 sync workload。

### 3.2 目录规范

```
argocd/
├── bootstrap/
│   └── root-appsets-prod.yaml     # 生产 L0；test 仓库对应 root-appsets-test.yaml
├── appsets/
│   ├── platform/
│   │   ├── git-cdn.yaml
│   │   ├── nginx-pypi-cache.yaml
│   │   └── ...
│   └── projects/
│       ├── ascend-ascend-ci.yaml
│       └── ...
├── cluster-values/
│   ├── ascend-hk-001-cluster.yaml
│   ├── cn12-001.yaml
│   └── ...
├── projects-values/
│   ├── ascend-ascend-ci.yaml
│   └── ...
├── projects/                      # AppProject 清单
│   ├── ascend-hk-001-cluster.yaml
│   └── ...
└── clusters/                      # 只保留尚未迁移的例外，最终清空
```

### 3.3 命名规范

| 对象 | 规则 | 例子 |
|---|---|---|
| ApplicationSet | `<env>-<service>` 或 `<env>-<project>` | `arc-prod-git-cdn`、`arc-prod-ascend-ascend-ci` |
| 生成的 Application | `<service>-<cluster-suffix>`，例外用 `appName` 覆盖 | `git-cdn-hk-001` |
| cluster-values | `<argocd-cluster-name>.yaml` | `ascend-hk-001-cluster.yaml` |
| project-values | `<org>-<repo>.yaml`，斜杠转 `-` | `ascend-ascend-ci.yaml` |
| AppProject | `<cluster>`，或共享 project 显式声明 | `ascend-hk-001-cluster` |

命名冲突是硬约束：test 和 prod 共用 hub，appset 对象名必须全局唯一，生产统一加 `arc-prod-` 前缀。

## 4. cluster-values 与启用机制

### 4.1 cluster-values schema

```yaml
cluster: ascend-hk-001-cluster   # ArgoCD cluster secret 的 name
suffix: hk-001                   # app 名后缀
project: ascend-hk-001-cluster   # AppProject
services:
  git-cdn:
    namespace: git-cdn
    # appName: git-cdn-hk-001    # 可选；默认 <service>-<suffix>
    # arch: amd64
    # hostPath: /data/nginx-cache
    # image: ...
    # overlay: ...
    # values: {...}              # Helm per-cluster 覆盖
```

### 4.2 服务分组

不要假设所有集群都需要所有服务。用 cluster secret 标签分组：

```yaml
metadata:
  labels:
    appset-group-base: "true"    # git-cdn/nginx/imagepull/squid/sfs...
    appset-group-liqo: "true"    # Liqo provider/provider-side
    appset-group-gpu: "true"     # npu-exporter/npu-scheduler
```

平台 appset 用 matrix：

```yaml
generators:
  - matrix:
      generators:
        - clusters:
            selector:
              matchLabels:
                appset-group-base: "true"
        - git:
            repoURL: https://github.com/opensourceways/ascend-ci-deployment.git
            revision: main
            files:
              - path: argocd/cluster-values/{{.name}}.yaml
```

这样：

- 新集群：注册 + AppProject + 1 个 cluster-values + 1~2 个 group 标签
- 新服务：1 个 appset；只对对应 group 的集群生效
- 不需要为每个服务复制 cluster-values

如果坚持“所有服务默认全上”，可以去掉 cluster generator，只用 git 文件生成器；但 Liqo/GPU 服务通常需要分组。

## 5. 平台服务 appset 模板

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: arc-prod-git-cdn
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
  syncPolicy:
    preserveResourcesOnDeletion: true
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  appset-group-base: "true"
          - git:
              repoURL: https://github.com/opensourceways/ascend-ci-deployment.git
              revision: main
              files:
                - path: argocd/cluster-values/{{.name}}.yaml
  template:
    metadata:
      name: '{{ dig "services" "git-cdn" "appName" (printf "git-cdn-%s" .suffix) . }}'
      namespace: argocd
    spec:
      project: '{{.project}}'
      destination:
        name: '{{.name}}'
        namespace: '{{ dig "services" "git-cdn" "namespace" "git-cdn" . }}'
      source:
        repoURL: https://github.com/opensourceways/ascend-ci-deployment.git
        targetRevision: HEAD
        path: manifests/git-cdn/chart
        helm:
          releaseName: git-cdn
          values: |
            {{- $base := fromYaml `
            namespace: git-cdn
            proxy:
              appName: git-cdn
              ...
            ` -}}
            {{- $override := dig "services" "git-cdn" "values" (dict) . -}}
            {{- mergeOverwrite (deepCopy $base) $override | toYaml | nindent 4 }}
      syncPolicy:
        automated:
          prune: true
          selfHeal: false
        syncOptions:
          - CreateNamespace=true
```

注意：

- `metadata.name` 对硬编码 app 名的服务必须支持 `appName` 覆盖，否则多集群会生成同名 app。
- `destination.name` 用 `.name`（cluster generator），不要和 `.cluster`（文件里的字段）混用。
- 不同 source 类型（Helm/kustomize/directory/multi-source）不要强行塞进一个 appset；按 source 类型或服务单独建。

## 6. Runner/项目模型

### 6.1 目标

把 PR #2382 这类 21 个文件的改动压成：

```text
argocd/projects-values/ascend-ascend-ci.yaml
manifests/runner-project/chart/...
argocd/appsets/projects/ascend-ascend-ci.yaml
```

项目 values：

```yaml
project: Ascend/Ascend-CI
namespace: ascend
cluster: sh-002
githubConfigUrl: https://github.com/Ascend/Ascend-CI
githubConfigSecret: ascend-ascend-ci-secret
runners:
  - name: linux-amd64-a5-1
    cards: 1
    cpu: "8"
    memory: 16Gi
    labels: ["linux-amd64-a5-1", "sh-002"]
  - name: linux-amd64-a5-2
    cards: 2
    cpu: "16"
    memory: 32Gi
    labels: ["linux-amd64-a5-2", "sh-002"]
  - name: linux-amd64-a5-4
    cards: 4
    ...
  - name: linux-amd64-a5-8
    cards: 8
    ...
```

chart 内：

```yaml
{{- range .Values.runners }}
---
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: {{ .name }}
...
{{- end }}
```

### 6.2 项目 appset

```yaml
generators:
  - git:
      repoURL: https://github.com/opensourceways/ascend-ci-deployment.git
      revision: main
      files:
        - path: argocd/projects-values/*.yaml
template:
  metadata:
    name: 'ascend-ascend-ci-{{.cluster}}'
  spec:
    project: '{{.project}}'
    destination:
      name: '{{.cluster}}'
      namespace: '{{.namespace}}'
    source:
      path: manifests/runner-project/chart
      helm:
        values: |
          {{- . | toYaml | nindent 12 }}
```

这里的关键不是 appset，而是 **chart 的 range 能力**：runner 数量、卡数、资源、labels 只写差异，不再复制完整 values/ConfigMap。

## 7. Hub bootstrap root

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-appsets-prod
  namespace: argocd
spec:
  project: hub-bootstrap-prod
  source:
    repoURL: https://github.com/opensourceways/ascend-ci-deployment.git
    targetRevision: HEAD
    path: argocd/appsets
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
```

test 仓库同构，只是：

- 名字 `root-appsets-test`
- project `hub-bootstrap`
- source `arc-fedsched/argocd/appsets`

- 只需要在 hub 上手工 apply 一次。
- 以后新增 appset 文件，merge 后 root 自动 apply；不需要人工 `kubectl apply -f argocd/appsets/...`。
- root `prune: false`，避免删文件连带删服务；appset 自身用 `preserveResourcesOnDeletion: true`。
- 生产 project 用 `hub-bootstrap-prod`，test 用 `hub-bootstrap`；不要复用 `cluster-roots`（它只放行 Application，不放行 ApplicationSet）。

## 8. 迁移 wave

### Wave 0：盘点与工具（1-2 天）

- 跑 inventory，把 1,014 个 Application 分类为 A 平台 / B runner / C 单例 / D ARC。
- 统一命名、前缀、group 标签。
- 补 CI：appset lint、schema、重名检查、render/parity。
- 选一个非关键集群做 pilot（gy-006 或 arc-prod；arc-prod 已完成 13 个平台服务，可作为 reference）。

### Wave 1：平台服务 pilot（一个集群）

- 选 3-5 个服务：git-cdn、nginx-pypi-cache、imagepullsecret-patch、nfs-storage、npu-exporter。
- 建 appset + cluster-values + AppProject。
- 对账 live `spec`、渲染、Pod age；不重启。
- 验证新增集群只加一个 cluster-values。

### Wave 2：平台服务全量

按风险从低到高：

1. 缓存：git-cdn、nginx-pypi-cache
2. 静态存储/监控：nfs-storage、npu-exporter
3. 存储/代理：sfs、squid
4. Secret/SA：imagepullsecret-patch、secrets-manager
5. 调度：npu-scheduler
6. Liqo：provider + provider-side
7. ARC controller：最后单独窗口

每一批只放**当前 Synced/Healthy 且 live spec 0 diff** 的服务；有既有 drift/CrashLoop 的先单独处理。

### Wave 3：Runner 项目 pilot

- 选一个项目、一个集群（如 Ascend/Ascend-CI → sh-002）。
- 写项目 values + 共享 chart，生成 4 个 runner + listener + ConfigMap。
- 与现有手写文件对比渲染；确认 pod template 0 diff。
- 先 dry-run/不接流，再切一个 runner。

### Wave 4：Runner 项目全量

- 按 org/repo 批量迁移；一个项目一个 values。
- 删除重复的 per-runner values/ConfigMap。
- 保留项目级差异（卡数、资源、labels、nodeSelector）。

### Wave 5：单例/厂商组件 + 清理

- dashboard、buildkit、karmada、监控 agent 等逐类迁移或标记例外。
- 删除 `argocd/clusters/` 下已迁空的目录、6 个多集群文件。
- `argocd/clusters` 只保留真正无法声明的例外。

### Wave 6：新集群 onboarding 验证

- 用一个新注册集群，只提交 AppProject + cluster-values + group 标签。
- 验证所有 catalog 服务自动生成；不修改任何 appset。
- 记录 onboarding 时间，目标 < 10 分钟（不含集群注册）。

## 9. 单服务迁移 runbook

1. **盘点**：`argocd/clusters/<cluster>/`、多集群文件、live Application spec。
2. **对账**：live `spec` 与仓库叶子逐字段比较；live Pod/DS/Deployment age/generation 记录。
3. **建 appset**：复制 source/syncPolicy；默认 values 与旧叶子一致；需要差异的字段用 `dig`/`mergeOverwrite`。
4. **加 cluster-values**：只写 namespace 和真正的差异；不复制整份 values。
5. **删旧叶子**：从 cluster 目录或多集群文件移除；root `prune: false`，不会删 app。
6. **本地验证**：`helm template`/`kustomize build`；appset 渲染后的 `metadata.name`/`source`/`syncPolicy` 与旧叶子 0 diff。
7. **apply/merge**：先 apply 新 appset，确认 app `Synced/Healthy`、ownerReference 指向 appset。
8. **检查 workload**：Pod 创建时间、RESTARTS、Deployment/DS generation 不变。
9. **回滚**：git revert + 重新 apply 旧叶子；appset `preserveResourcesOnDeletion: true` 保资源。

## 10. CI/工具建议

新增/扩展：

- `tools/appset_inventory.py`：扫描 `argocd/clusters`、`argocd/appsets`、`argocd/cluster-values`，输出类型/数量/重名/归属。
- `tools/appset_validate.py`：
  - appset 名字前缀、generator 路径只允许 `argocd/cluster-values/*.yaml`
  - cluster-values schema（cluster/suffix/project）
  - 生成 app 名全局唯一（含硬编码 `appName`）
  - 每个 appset 的 project 在 `argocd/projects/` 有定义
  - 每个 group 标签至少有一个集群
- `scripts/argocd-app-lint.sh` 扩展到 `argocd/appsets/`：
  - 不能有直接 Application（只允许 ApplicationSet）
  - template 必须有 project/destination/source
  - `syncPolicy.automated.prune` 必须显式
- CI 增加 appset render dry-run（helm template / kustomize build）和 duplicate app name 检查。
- 迁移 PR 必须附带 parity 结果：`spec diff=0`、Pod age/generation 不变。

## 11. 安全与回滚

- root：`prune: false`、`selfHeal: false`。
- appset：`preserveResourcesOnDeletion: true`。
- 迁移 PR 只改 Application 归属，不改 Pod template/镜像/资源/存储。
- 一次只迁一个服务或一批 **Synced/Healthy + 0 diff** 的服务；不把既有 drift 混进来。
- ARC controller / runner / listener / scale set 最后，单独审批、单独窗口。
- 回滚优先级：git revert > 重新 apply 旧叶子 > 删 appset。不要把删 appset 当第一手段。
- 任何意外 rollout 立即暂停，先看 `kubectl diff`/ArgoCD diff，再决定。

## 12. 验收标准

- 新集群：注册 + 1 个 AppProject + 1 个 cluster-values + group 标签；不改 appset/root。
- 新平台服务：1 个 appset 文件；对应 group 的集群自动生成。
- 新 runner 项目：1 个项目 values + 1 个 appset/chart entry；runner/listener 全部生成。
- `argocd/clusters/` 只剩明确例外；6 个多集群文件退役。
- 除 bootstrap root/AppProject 外，不再需要手工 `kubectl apply`。
- CI 能拦住：重名 app、错误 generator、缺失 project、非法 cluster-values。
- 所有迁移服务 `Synced/Healthy`；迁移过程中 Pod/DS/Deployment 无重启。
- 新增集群 onboarding 可复现，且有 runbook/测试。

## 13. 开放问题

1. **group 粒度**：base/liqo/gpu/runner 够不够？是否需要 per-service group？
2. **AppProject**：继续一集群一个，还是允许多 destination 的共享 project？
3. **Runner chart**：一个通用 chart 还是按 org 分 chart？listener/ConfigMap 是否都进 chart？
4. **单例/厂商组件**：哪些允许永久留在 `argocd/clusters` 作为例外？
5. **ARC/Liqo**：是否进 catalog，还是永久 standalone？
6. **bootstrap 权限**：`hub-bootstrap` project 是否能创建 ApplicationSet/Application，是否需要 cluster-admin 之外的收敛？
7. **命名**：test 和 prod 是否统一 `<env>-` 前缀；历史 app 是否借迁移顺便重命名（不建议）。

## 14. 建议的第一周

1. 跑 inventory，产出 1,014 个 Application 的分类表。
2. 定 group 标签和命名；先不改业务。
3. 把 arc-prod 的 13 个平台服务作为 reference，复制到第二个非关键集群（gy-006）。
4. 补 `appset_validate.py` + CI，先把门禁立起来。
5. 选一个 runner 项目做 chart range PoC，不接流。
6. 第一周结束前只合“工具 + pilot”，不合全量迁移 PR。