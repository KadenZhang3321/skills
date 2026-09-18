# Ascend CI 共享磁盘 / PVC 审计（完整版）

本文两部分：**Part I** 为 2026-09-18 只读 kubectl 采集的 PVC/物理盘归属盘点与 nginx max_size 生效核对（backlog#2279 跟进）；**Part II** 为 2026-09-14 一次性 Job `du` 实测的各共享盘目录用途/占用盘点（原文保留）。两部分的物理盘可互相对照，如 hk-001 `d5b643e2`（Part I 44-PVC 共享盘）= Part II 的 verl/RL CI 缓存盘，gy-005 `b46afb97`（squid-subpath）= Part II 的 gy003/005 共用 benchmarks 大盘。

> 关联 issue：[opensourceways/backlog#2279](https://github.com/opensourceways/backlog/issues/2279)（nginx-pypi-cache 各集群 max_size 总和超物理卷容量，跟进生效与共享占用治理），专项 [#2171](https://github.com/opensourceways/backlog/issues/2171) 共享磁盘优化专项，关联 [#2173](https://github.com/opensourceways/backlog/issues/2173) 共享盘文件来源分析。
>
> **数据采集**：2026-09-18，全程只读（`kubectl get pvc/pv/sc`、读取 live ConfigMap），未对集群做任何修改。
> 物理盘归属识别方法：Huawei everest CSI 的 PV `spec.csi.volumeAttributes["everest.io/volume-id"]`——同一个 `volume-id` 下的所有 PVC **共享同一块 SFS Turbo 物理卷**（subpath 动态供应，PV 申请量 ≠ 实际占用，也不受 PV 容量约束）。

---

## I.1 结论速览

1. **一个集群一块“大共享盘”**：各集群几乎所有 `sfsturbo-subpath-sc` PVC 都挂在**同一块**物理 SFS Turbo 上（gy-005 / infra-gy-001 另有一块独立的 squid/harbor 共享盘）；**nginx-pypi-cache、git-cdn、harbor、squid、runner 工作盘（-work）、模型/数据集缓存等所有租户都挤在同一块盘上**。cn12-001 上该共享盘挂了 **220 个 PVC**，hk-001 挂 44 个，gy-006 挂 25 个（即 issue 中说的 421G 现场）。
2. **max_size 收紧（#1695）生效核对**：`-new` 布局（400G）与 gy-006 `-test` 布局（50G）已在全部可达集群随 ArgoCD 生效、pod 已滚动。
3. **两个缺口**：① cn12-001 走 `nginx-pypi-cache-v2` 目录（ArgoCD app `nginx-pypi-cache-cn12-001` 的 sourcePath），#1695 只改了 `-new` 和 `-test`，**v2 的 live CM 仍是 1480G 未收紧**；② sh-002 集群同样部署了 pypi-cache 且为 1480G 旧配置（不在 issue 的 8 集群表内）。
4. **gy-006 残留旧 CM** `pypi-cache-conf`（无 hash 后缀、1480G 版）仍存在于 ns 中，但 deployment 已挂载新的 `pypi-cache-conf-dk2f7975gt`（50G），旧 CM 为孤儿对象（建议后续清理，本次未动）。
5. sh-001 / suzhou-lab-shanghai1 的 nginx 缓存被 ArgoCD patch 成 **hostPath**（`/data/nginx-cache`、`/mnt/share/ascend-ci/nginx-cache`），不经过 PVC；sh-001 全集群 **0 个 PVC**。
6. issue 表中 **wlcb-001（ascend-infra-wlcb-cluster-001，API 1.92.221.43:5443）本地无 kubeconfig，未采集**；infra-monitoring-cn4 与 osinfra-hk-test 的 kubeconfig 无 PVC 列举权限（Forbidden），未采集。

## I.2 集群与共享物理盘总览

issue #2279 原表（2026-09-17 实测物理容量/使用率）+ 本次 PVC 采集结果：

| 集群 | ArgoCD 名 | 区域 | 布局 | 物理卷 (issue) | 已用 (issue) | PVC 总数 | subpath 共享盘上的 PVC 数 | 备注 |
|---|---|---|---|---|---|---|---|---|
| **hk-001** | ascend-hk-001-cluster | ap-southeast-1 | -new | 6.0T | 574G (10%) | 93 | 44 |  |
| **cn12-001** | ascend-cn12-001-cluster | cn-north-12 | v2 | 2.4T | 1.4T (56%) | 271 | 220 | ⚠ max_size 未收紧（v2） |
| **gy-003** | openmerlin-guiyang-003-cluster | cn-southwest-2 | -new | 1.2T | 45G (4%) | 52 | 10 |  |
| **gy-004** | openmerlin-guiyang-004-cluster | cn-southwest-2 | -new | 1.2T | 20G (2%) | 79 | 57 |  |
| **gy-005** | openmerlin-guiyang-005-cluster | cn-southwest-2 | -new | 500G | 62G (13%) | 47 | 9 | 另有 squid-subpath 独立盘 |
| **gy-006** | openmerlin-guiyang-006-cluster | cn-southwest-2 | -test | 500G | 421G (85%) | 58 | 26 | 421G 现场；旧 CM 残留 |
| **infra-gy-001** | ascend-infra-guiyang-cluster-001 | cn-southwest-2 | -new | 3.6T | 2.0T (56%) | 68 | 23 | 另有 harbor-subpath 独立盘 |
| **aiframework** | ascend-aiframework | cn-north-12 | -new | — | — | 42 | 21 | issue 表外（cn-north-12，同走 -new） |
| **mind-third-ci** | ascend-mind-third-ci（ArgoCD: hb-003-verl） | cn-north-12 | -new | — | — | 45 | 21 | issue 表外（ArgoCD 名 hb-003-verl） |
| **sh-001** | openmerlin-sh-001-cluster | - | -new (hostPath) | — | — | 0 | 0 | 0 PVC，nginx 缓存走 hostPath |
| **sh-002** | sh-002 | - | -new | — | — | 6 | 5 | issue 表外；nginx PVC Pending |
| **wlcb-001** | ascend-infra-wlcb-cluster-001 | cn-north-12? | -new | 1.2T | 4.4G (1%) | — | — | ❌ 无 kubeconfig，未采集 |
| infra-hk-opensourceway-ci (hk-ci) | 同左 | - | -new | — | — | — | — | ❌ 无 kubeconfig |
| suzhou-lab-shanghai1 | 同左 | - | -new+hostPath | — | — | — | — | ❌ 无 kubeconfig |
| infra-cn4-x86-common | monitoring-cn4 | - | - | — | — | — | — | ❌ RBAC Forbidden |
| osinfra-hk-test-cluster | cla | - | - | — | — | — | — | ❌ RBAC Forbidden |

## I.3 共享物理盘（subpath SFS Turbo）分组明细

同一 `volume-id` = 同一块物理 SFS Turbo。`Σ申请` 为各 PVC `resources.requests.storage` 之和——**subpath 模式下这只是占位申请，互不约束，真实占用看 `df`**；`Σ申请` 远大于物理卷容量是常态（超卖），这也是 issue 中 nginx max_size 总和超卷才会写爆的原因。

| 集群 | SC | volume-id | 挂载 PVC 数 | Σ申请 | nginx 缓存卷 | 主要租户 (namespace: PVC 数) |
|---|---|---|---|---|---|---|
| hk-001 | sfsturbo-subpath-sc | `d5b643e2-b838-4109-9ba5-f762a99daee9` | 44 | 4.6Ti | ✅ pypi-cache-data-volume | vllm-project×36, squid×2, ascend×1, cosdt×1, nginx-pypi-cache×1, sgl-project×1, smart-git-proxy×1, xuedinge233×1 |
| cn12-001 | sfsturbo-subpath-sc | `665a3415-80ff-4388-b452-773448c8a74f` | 220 | 16.8Ti | ✅ pypi-cache-data-volume | sgl-project-sglang×158, vllm-project-vllm-ascend×39, ascend-pytorch×11, squid×4, triton-ascend×4, buildkitd×1, git-cdn×1, nginx-pypi-cache×1 |
| gy-003 | sfsturbo-subpath-sc | `0ca03ada-9d51-4b2c-83a4-f03f079a6963` | 10 | 1.4Ti | ✅ pypi-cache-data-volume | vllm-project×8, git-cdn×1, nginx-pypi-cache×1 |
| gy-004 | sfsturbo-subpath-sc | `e745888b-ec2c-49d6-b16a-b0372402d843` | 57 | 4.6Ti | ✅ pypi-cache-data-volume | sgl-project-sglang×54, git-cdn×1, nginx-pypi-cache×1, sgl-project×1 |
| gy-005 | sfsturbo-subpath-sc | `95a3d42c-f6ed-41e2-91d0-c3a113b10792` | 5 | 1.8Ti | ✅ pypi-cache-data-volume | ascend-pytorch×1, git-cdn×1, nginx-pypi-cache×1, smart-git-proxy×1, vllm-project-vllm-ascend×1 |
| gy-005 | squid-subpath-sc | `b46afb97-6954-11f1-af0f-fa16412f71d0` | 4 | 1.2Ti | — | squid×4 |
| gy-006 | - / sfsturbo-subpath-sc（含静态 NFS 直挂） | `45eb5e4c-ea7c-4ae2-a0c1-f84867ce74e1` | 26 | 10.9Ti | ✅ pypi-cache-data-volume | argo×5, harbor×4, squid×4, ascend-gha-runners×3, git-cdn×1, mindstudio×1, monitoring×1, nginx-pypi-cache×1 |
| infra-gy-001 | sfsturbo-subpath-sc | `d561f410-2692-4a18-9c3f-bbfcd3b6012f` | 15 | 1.8Ti | ✅ pypi-cache-data-volume | cosdt-ci-test×7, argo×2, op-plugin×2, ascend-data-sync×1, git-cdn×1, nginx-pypi-cache×1, ragsdk×1 |
| infra-gy-001 | harbor-subpath-sc | `488cfc84-5378-11f1-8401-fa16412f71d0` | 8 | 2.8Ti | — | harbor×4, squid×4 |
| aiframework | sfsturbo-subpath-sc | `ba20b346-a7bd-48aa-9a41-3dbf0c7c03a6` | 21 | 2.5Ti | ✅ pypi-cache-data-volume | vllm-project-vllm-ascend×15, ascend-pytorch×3, ascend-gha-runners×1, git-cdn×1, nginx-pypi-cache×1 |
| mind-third-ci | sfsturbo-subpath-sc | `a8317f79-8762-4a9c-a18c-ebae7ce2ad0e` | 21 | 2.4Ti | ✅ pypi-cache-data-volume | vllm-project-vllm-ascend×12, ascend-pytorch×7, git-cdn×1, nginx-pypi-cache×1 |
| sh-002 | - | `179.60.12.2` | 5 | 5.9Ti | — | ascend-gha-runners×1, ascend-pytorch×1, sgl-kernel-npu×1, sgl-project×1, triton-ascend×1 |

其余 PVC 均为**每 PVC 独占**的动态卷（`csi-sfsturbo` = 独立 SFS Turbo、`csi-disk*` = EVS 磁盘、`csi-sfs` = SFS、`local`/static NFS），不存在跨租户共享问题，见 I.5 逐集群清单中“底层”列为 `独立*` 的行。

## I.4 nginx max_size 收紧生效核对（live ConfigMap，2026-09-18）

| 集群 | deployment 挂载的 CM | 各缓存 max_size | Σ max_size | 状态 |
|---|---|---|---|---|
| hk-001 | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| cn12-001 | `pypi-cache-conf-7c5m265bfh` | 500G+500G+200G+200G+200G+80G (含 crates) | 1480G | ⚠ 未收紧（v2 目录未被 #1695 覆盖） |
| gy-003 | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| gy-004 | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| gy-005 | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| gy-006 | `pypi-cache-conf-dk2f7975gt` | 20G+10G+6G+5G+6G+3G (含 crates) | 50G | 收紧后 ✓（旧 1480G 版 CM 残留） |
| infra-gy-001 | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| aiframework | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| mind-third-ci | `pypi-cache-conf` | 150G+100G+60G+60G+30G | 400G | 收紧后 ✓ |
| sh-002 | `pypi-cache-conf` | 500G+500G+200G+200G+80G | 1480G | ⚠ 未收紧，且缓存 PVC Pending |
| wlcb-001 | — | 预期 -new 400G | — | ❌ 无 kubeconfig，需有权同学核对 |

**待跟进**：
- [ ] cn12-001 的 `manifests/nginx-pypi-cache-v2/*` 需同步 #1695 的收紧值（或把 cn12 app 切回 `-new` 布局）；其物理卷 2.4T、已用 56%，1480G 上限虽未超物理卷但与“按最小部署卷 80% 封顶”的统一口径冲突。
- [ ] sh-002 的 `-new` 部署未滚动到收紧版（live CM 仍是 1480G 旧值，且 `pypi-cache-data-volume` Pending、nginx pod 未挂 PVC）——需确认该集群 ArgoCD app 状态。
- [ ] gy-006 孤儿 CM `pypi-cache-conf`（1480G 旧版）可删除。
- [ ] gy-006 共享盘 421G 实际占用治理（harbor registry 2Ti 申请、nv-action/kimi-k3 等）——见 issue 验收项 3。

## I.5 各集群 PVC 全量清单

字段：底层列 = 共享盘时给出物理卷 `volume-id` 前 8 位（同值即同物理卷，含静态 NFS 直挂到同盘的）；`独立:xxx` = 每 PVC 独占卷（xxx 为 CSI 驱动类型）。容量列为申请值（subpath 模式为占位、可超卖）。

### I.5.1 hk-001 — ascend-hk-001-cluster

kubeconfig: `~/.kube/configs/ascend-hk-001-cluster-kubeconfig.yaml` ｜ 区域 `ap-southeast-1` ｜ nginx 布局 `-new` ｜ PVC 共 **93** 个

按 StorageClass：`csi-sfsturbo`×46，`sfsturbo-subpath-sc`×45，`csi-disk-topology`×1，`csi-disk-dss`×1 ｜ 状态：Bound×93

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | ascend | linux-aarch64-a2-2-vdwdr-runner-jwp92-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 2 | cosdt | linux-aarch64-a2-2-bnwql-runner-8ch99-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 3 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 4 | sgl-project | linux-aarch64-a2-1-qh5bv-runner-x47pz-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 5 | smart-git-proxy | smart-git-proxy-mirrors | Bound | 500Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 6 | squid | registry-cache-pvc | Bound | 400Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 7 | squid | squid-cache-pvc | Bound | 200Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 8 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-22lz8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 9 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-2f6wk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 10 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-4xszh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 11 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-6tg2x-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 12 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-6xbf2-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 13 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-c6bn9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 14 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-cvtvl-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 15 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-fnj9b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 16 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-fs9hl-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 17 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-g86n8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 18 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-gkms8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 19 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-hshhh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 20 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-hxsx7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 21 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-lmrdb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 22 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-lpklg-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 23 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-lr5rv-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 24 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-lv5k4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 25 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-lvpn9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 26 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-lwqgp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 27 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-m8btg-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 28 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-mjqst-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 29 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-mszbb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 30 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-n99rc-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 31 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-plndx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 32 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-sdvkr-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 33 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-tf9bs-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 34 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-tt6b7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 35 | vllm-project | linux-aarch64-a2b3-1-gq296-runner-v4s5r-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 36 | vllm-project | linux-amd64-cpu-2-hk-r22s6-runner-crm79-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 37 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-b8ml5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 38 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-cgv48-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 39 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-kd88b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 40 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-pr2f4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 41 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-s4v59-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 42 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-th8mx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 43 | vllm-project | linux-amd64-cpu-8-hk-pqz7r-runner-vpcrx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 44 | xuedinge233 | linux-aarch64-a2-2-5vqxw-runner-fw6hx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d5b643e2…` |
| 45 | vault | data-vault-0 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 46 | monitoring | pvc-prometheus-server-0 | Bound | 200Gi | csi-disk-topology | 独立:disk |
| 47 | ascend | ascend-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 48 | ascend | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 49 | ascend-docs | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 50 | ascend-gha-runners | ascend-gha-runners-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 51 | ascend-gha-runners | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 52 | ascend-gha-runners | pvc-hk001-sglang | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 53 | ascend-gha-runners | pvc-hk001-vllm | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 54 | ascend-gha-runners | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 55 | ascend-gha-runners-hk-001 | vllm-ascend-hk-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 56 | codemayq-transformers | codemayq-transformers-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 57 | cosdt | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 58 | fla-org-flash-linear-attention | fla-org-flash-linear-attention-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 59 | ganding-rlinf | ganding-rlinf-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 60 | gdzhu01 | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 61 | goalina-transformers | goalina-transformers-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 62 | hiyouga | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 63 | linkedin | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 64 | modelscope | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 65 | monitoring | pvc-cache-cleanup-hk-cidev | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 66 | monitoring | pvc-cache-cleanup-hk-d5share | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 67 | monitoring | pvc-cache-cleanup-hk-nvbench | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 68 | monitoring | pvc-cache-cleanup-hk-sglang | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 69 | monitoring | pvc-cache-cleanup-hk-share | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 70 | nginx-test | test | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 71 | nv-action | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 72 | pt-ecosystem-flash-linear-attention-dev | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 73 | pytorch-fdn | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 74 | sfs-local-mount | pvc-sfs-turbo-local-mount.c5803d39-6bf4-46dd-b6ad-983e0631cb8e | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 75 | sfs-local-system | ascend-ci-share-pkking-sglang | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 76 | sfs-local-system | ascend-gha-runners-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 77 | sfs-system | cleanup-sfs-turbo-for-ascend-verl-ci | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 78 | sgl-kernel-npu | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 79 | sgl-project | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 80 | sgl-project-sglang-omni | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 81 | triton-ascend | ascend-triton-ascend-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 82 | usernamefull-transformers-ci | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 83 | verl-project-uni-agent | verl-uni-agent-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 84 | verl-project-verl-speco | verl-verl-speco-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 85 | vllm-ascend-ci-dev-vllm-ascend | vllm-ascend-ci-dev-vllm-ascend-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 86 | vllm-ascend-main2main-automator | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 87 | vllm-ascend-vllm-ascend-kimi-k3 | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 88 | vllm-project | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 89 | vllm-project-vllm-ascend | vllm-ascend-sz-lab | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 90 | volcengine | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 91 | xuedinge233 | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 92 | xuedinge233-triton-ascend | triton-ascend-hk001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 93 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 独立:sfsturbo |

### I.5.2 cn12-001 — ascend-cn12-001-cluster

kubeconfig: `~/.kube/configs/ascend-cn12-001-cluster-kubeconfig.yaml` ｜ 区域 `cn-north-12` ｜ nginx 布局 `v2` ｜ PVC 共 **271** 个

按 StorageClass：`sfsturbo-subpath-sc`×220，`csi-sfsturbo`×42，`csi-disk-topology`×8，`csi-disk-dss`×1 ｜ 状态：Bound×271

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-8wvwx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 2 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-dmsx8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 3 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-rklhv-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 4 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-tjwpd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 5 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-v56bh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 6 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-c2zq4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 7 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-c4dkp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 8 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-j6dx5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 9 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-k668k-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 10 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-n9764-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 11 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-t8np7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 12 | buildkitd | test | Bound | 10Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 13 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 14 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`665a3415…` |
| 15 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-57npf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 16 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-5q57g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 17 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-7cs2g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 18 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-7fjk5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 19 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-7lnqb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 20 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-8rgj7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 21 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-9dsfh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 22 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-9mwlh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 23 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-bzk89-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 24 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-fhjq5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 25 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-jm47q-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 26 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-kb7c7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 27 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-lcplx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 28 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-mplcq-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 29 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-qf2sz-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 30 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-tcknb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 31 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-xjqgk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 32 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-xv6cs-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 33 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-zmxtk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 34 | sgl-project-sglang | linux-aarch64-a3-16-cn12-001-ngs84-runner-zpcx6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 35 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-2b76m-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 36 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-5qknm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 37 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-66nz6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 38 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-7lqwd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 39 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-7nbm5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 40 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-7pr7q-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 41 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-9xf28-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 42 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-bpsq4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 43 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-bxnfp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 44 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-c5f7g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 45 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-dlvf5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 46 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-f67js-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 47 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-fcq6x-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 48 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-fmzsr-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 49 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-fs4b9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 50 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-g27gg-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 51 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-gf4lh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 52 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-gwpn7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 53 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-gx9ml-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 54 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-j6l2k-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 55 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-kh694-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 56 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-lcsgp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 57 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-lgnnd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 58 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-lkntz-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 59 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-m8ff9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 60 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-mj554-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 61 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-prxg9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 62 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-r5q2h-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 63 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-r89mt-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 64 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-r8m5k-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 65 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-rdhvb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 66 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-s7pw7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 67 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-t7lj6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 68 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-vq4kg-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 69 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-vw4lq-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 70 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-w8fnn-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 71 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-xfb89-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 72 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-xxzn8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 73 | sgl-project-sglang | linux-aarch64-a3-2-cn12-001-4tp4h-runner-zxcqp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 74 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-2lpz6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 75 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-4kqqj-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 76 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-59s5c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 77 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-5pcwq-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 78 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-67829-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 79 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-6pprr-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 80 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-crz55-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 81 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-d5865-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 82 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-d9bmt-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 83 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-f52vb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 84 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-gwxb5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 85 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-k7z95-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 86 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-l4gnl-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 87 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-qv2rr-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 88 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-rkm49-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 89 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-scxzw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 90 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-w5fl6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 91 | sgl-project-sglang | linux-aarch64-a3-4-cn12-001-sjbhl-runner-z6s59-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 92 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-2frqh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 93 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-84nf8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 94 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-8rvm9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 95 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-98k99-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 96 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-gdfrx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 97 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-kcg6l-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 98 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-kt48p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 99 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-wt2kc-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 100 | sgl-project-sglang | linux-aarch64-a3-8-cn12-001-d9b2b-runner-x4gzz-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 101 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-5pbjw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 102 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-6kp5n-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 103 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-fjxbb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 104 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-r8j7w-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 105 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-rkg64-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 106 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-29rb6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 107 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-2pvj8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 108 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-5ld6c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 109 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-5wf6r-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 110 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-6dhpf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 111 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-6n7k8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 112 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-7lkk7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 113 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-8fglf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 114 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-9nwhb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 115 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-9zvv5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 116 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-b59gw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 117 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-fkjhh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 118 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-fp68p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 119 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-frlsh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 120 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-g6pf6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 121 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-gf6hn-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 122 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-gwh6h-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 123 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-hf44c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 124 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-k5hfg-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 125 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-k6bcs-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 126 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-kv8n4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 127 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-ltvv8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 128 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-n2xmx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 129 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-ndr4l-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 130 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-pgt2v-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 131 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-pqtjk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 132 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-q5hxr-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 133 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-qwljj-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 134 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-r82sj-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 135 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-rfmdb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 136 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-rwqh8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 137 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-s9pss-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 138 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-tbn44-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 139 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-w2wgb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 140 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-xxl42-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 141 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-xzznh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 142 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-26r6s-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 143 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-4f9dl-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 144 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-4v8m9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 145 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-59xv9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 146 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-7hpvv-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 147 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-7px8f-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 148 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-bf8ms-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 149 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-bg87g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 150 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-dh58g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 151 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-f9jx5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 152 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-jgknk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 153 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-jgpjf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 154 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-jv28n-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 155 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-kpmn5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 156 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-lhmf4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 157 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-n4jhz-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 158 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-njjlk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 159 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-pd279-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 160 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-pk5hm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 161 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-q87hg-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 162 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-qxzjn-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 163 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-r4ndd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 164 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-s28gm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 165 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-s2czm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 166 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-t847b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 167 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-twfxf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 168 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-v4586-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 169 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-v9nn2-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 170 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-vfdns-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 171 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-vsv56-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 172 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-xznv4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 173 | squid | cache-squid-cache-0 | Bound | 200Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 174 | squid | cache-squid-cache-1 | Bound | 200Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 175 | squid | registry-cache-squid-cache-0 | Bound | 400Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 176 | squid | registry-cache-squid-cache-1 | Bound | 400Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 177 | triton-ascend | linux-aarch64-cpu-4-buildkit-cn12-001-zqxc7-runner-28x47-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 178 | triton-ascend | linux-aarch64-cpu-4-buildkit-cn12-001-zqxc7-runner-4b66h-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 179 | triton-ascend | linux-amd64-cpu-4-buildkit-cn12-001-hssmt-runner-55ph5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 180 | triton-ascend | linux-amd64-cpu-4-buildkit-cn12-001-hssmt-runner-vgxsh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 181 | usernamefull | usernamefull-roll-cn12-001 | Bound | 1.2Ti | sfsturbo-subpath-sc | 共享`665a3415…` |
| 182 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-5829p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 183 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-5hrp2-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 184 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-7dv2f-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 185 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-96ztm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 186 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-9l8fb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 187 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-c7lzt-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 188 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-jbqtv-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 189 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-lzb2p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 190 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-lztrf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 191 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-pphdw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 192 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-pr77c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 193 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-rt2ld-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 194 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-vg9hx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 195 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-vlgrx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 196 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-xv7rf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 197 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-xxcn8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 198 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-zmf8k-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 199 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-6v9z8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 200 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-6vhnx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 201 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-78m4g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 202 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-7z5mk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 203 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-95t9q-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 204 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-bcrl4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 205 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-fmgrd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 206 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-gqhmh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 207 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-k42d6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 208 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-kgv5p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 209 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-lz4fk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 210 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-nzjpw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 211 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-pss8b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 212 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-q425t-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 213 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-rb44s-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 214 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-rjvw5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 215 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-stbts-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 216 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-zk82c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 217 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-8-cn12-001-xms7p-runner-5qwqp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 218 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-8-cn12-001-xms7p-runner-pw8m2-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 219 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-8-cn12-001-xms7p-runner-t74vt-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 220 | vllm-project-vllm-ascend | linux-aarch64-a3-800t-0-g77hq-runner-gmbjk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`665a3415…` |
| 221 | vault | data-vault-0 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 222 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-0 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 223 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-1 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 224 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-2 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 225 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-3 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 226 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-0 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 227 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-1 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 228 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-2 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 229 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-3 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 230 | alibaba-roll | alibaba-roll-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 231 | alibaba-roll-liqo | alibaba-roll-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 232 | areal-project-areal | areal-project-areal-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 233 | areal-project-areal | areal-project-areal-shared-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 234 | ascend | ascend-sglang-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 235 | ascend | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 236 | ascend-docs | ascend-docs-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 237 | ascend-gha-runners | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 238 | ascend-gha-runners | omni-hb003 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 239 | ascend-gha-runners | sglang-public-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 240 | ascend-gha-runners-gy004 | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 241 | ascend-gha-runners-gy005 | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 242 | ascend-gha-runners-gy005 | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 243 | ascend-gha-runners-gy006 | ascend-gha-runners-vllm-ascend-gy006 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 244 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 245 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 246 | liqo-test | liqo-test-share | Bound | 14.4Ti | csi-sfsturbo | 独立:sfsturbo |
| 247 | monitoring | pvc-cache-cleanup-cn12-share | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 248 | nv-action | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 249 | sfs-local-mount | pvc-sfs-turbo-local-mount.8258ca0d-8dce-4a35-8802-79d10e0f8f9f | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 250 | sfs-local-system | ascend-ci-share | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 251 | sfs-local-system | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 252 | sgl-kernel-npu | sglang-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 253 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 254 | sgl-project-sglang | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 255 | sgl-project-sglang | sglang-shared-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 256 | tecjesh-triton-ascend | triton-ascend-cn12-001-pvc | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 257 | tile-ai-tilelang-mlir-ascend | tile-ai-tilelang-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 258 | tile-ai-tilelang-mlir-ascend-liqo | tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 259 | triton-ascend | ascend-triton-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 260 | triton-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 261 | triton-ascend-liqo | triton-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 262 | verl-project-liqo | verl-project-liqo-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 263 | verl-project-liqo | verl-project-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 264 | vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 265 | vllm-ascend-vllm-ascend-recipes | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 266 | vllm-project | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 267 | vllm-project | test | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 268 | vllm-project | vllm-omni-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 269 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 270 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 271 | vllm-project-vllm-omni | vllm-project-vllm-omni-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.3 gy-003 — openmerlin-guiyang-003-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-003-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **52** 个

按 StorageClass：`csi-sfsturbo`×30，`csi-disk`×10，`sfsturbo-subpath-sc`×10，`csi-sfs`×1，`csi-disk-topology`×1 ｜ 状态：Bound×52

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 2 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 3 | vllm-project | linux-aarch64-310p-1-58kc6-runner-4pz8j-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 4 | vllm-project | linux-aarch64-310p-1-58kc6-runner-9z265-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 5 | vllm-project | linux-aarch64-310p-1-58kc6-runner-dfmxb-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 6 | vllm-project | linux-aarch64-310p-1-58kc6-runner-mcx2f-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 7 | vllm-project | linux-aarch64-310p-4-jhhlb-runner-2bkl4-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 8 | vllm-project | linux-aarch64-310p-4-jhhlb-runner-7wjlf-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 9 | vllm-project | linux-aarch64-310p-4-jhhlb-runner-888m7-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 10 | vllm-project | linux-aarch64-310p-4-jhhlb-runner-9k5p8-work | Bound | 32Gi | sfsturbo-subpath-sc | 共享`0ca03ada…` |
| 11 | coder | coder-00eb6ddf-5562-4d7c-8553-101763fbd4a6-home | Bound | 1000Gi | csi-disk | 独立:disk |
| 12 | coder | coder-1de3c53e-25bd-4657-a9de-7aa7bf158bc9-home | Bound | 100Gi | csi-disk | 独立:disk |
| 13 | coder | coder-324724f5-0445-42ee-b11b-3db3ab7bf650-home | Bound | 100Gi | csi-disk | 独立:disk |
| 14 | coder | coder-5c8888bf-8728-4413-815b-4fd17ee5f147-home | Bound | 100Gi | csi-disk | 独立:disk |
| 15 | coder | coder-8418dc3c-d6da-4810-8e39-53833602e9be-home | Bound | 100Gi | csi-disk | 独立:disk |
| 16 | coder | coder-95f186a6-0474-40cb-a29d-948b4365d02e-home | Bound | 100Gi | csi-disk | 独立:disk |
| 17 | coder | coder-9c83e2c0-5daf-4c24-a530-c63dbb974c8e-home | Bound | 100Gi | csi-disk | 独立:disk |
| 18 | coder | coder-c64e61cc-5e5e-47c3-bbae-00781f9df657-home | Bound | 100Gi | csi-disk | 独立:disk |
| 19 | coder | coder-cece37ec-2241-4ba3-840a-0e4a608b8b50-home | Bound | 200Gi | csi-disk | 独立:disk |
| 20 | npu-exporter | prometheus | Bound | 10Gi | csi-disk | 独立:disk |
| 21 | monitoring | grafana-pvc | Bound | 105Gi | csi-disk-topology | 独立:disk |
| 22 | cllouud | test | Bound | 1Gi | csi-sfs | 独立:nas |
| 23 | arc-systems | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 24 | ascend | ascend-ci-share-ascend-ascend-ci | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 25 | ascend | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 26 | ascend-gha-runners | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 27 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 28 | ascend-gha-runners | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 29 | ascend-gha-runners | nv-action-vllm-benchmarks-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 30 | cllouud | ascend-ci-hook-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 31 | cllouud | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 32 | cllouud | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 33 | cllouud | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 34 | coder | sfs-turbo-coder | Bound | 2.4Ti | csi-sfsturbo | 独立:sfsturbo |
| 35 | cosdt | ascend-ci-share-cosdt | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 36 | cosdt | cosdt-store | Bound | 100Mi | csi-sfsturbo | 独立:sfsturbo |
| 37 | cosdt | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 38 | listener-pod-persistence | prometheus-pvc | Bound | 200Gi | csi-sfsturbo | 独立:sfsturbo |
| 39 | model-download | model-download-cache | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 40 | monitoring | pvc-cache-cleanup-gy003-230nv | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 41 | monitoring | pvc-cache-cleanup-gy003-39a | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 42 | monitoring | pvc-cache-cleanup-gy003-b46nv | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 43 | nv-action | ascend-ci-hook-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 44 | nv-action | ascend-ci-share-nv-action-vllm-benchmarks | Bound | 500Gi | csi-sfsturbo | 独立:sfsturbo |
| 45 | nv-action | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 46 | nv-action | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 47 | pytorch-fdn | ascendci-pytorch-fdn-oota | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 48 | pytorch-fdn | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 49 | sfs-system | cleanup-sfs-turbo-ascend-ci-02 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 50 | vllm-ascend-ci-dev-vllm-ascend | vllm-ascend-ci-dev-vllm-ascend-gy003 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 51 | vllm-project | gy003-az5-vllm-ascend | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 52 | vllm-project | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.4 gy-004 — openmerlin-guiyang-004-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-004-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **79** 个

按 StorageClass：`sfsturbo-subpath-sc`×57，`csi-sfsturbo`×22 ｜ 状态：Bound×79

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 2 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`e745888b…` |
| 3 | sgl-project | linux-amd64-cpu-4-xgxwx-runner-f79vw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 4 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-5pbjw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 5 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-6kp5n-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 6 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-fjxbb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 7 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-r8j7w-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 8 | sgl-project-sglang | linux-aarch64-a3-800t-16-cn12-001-ddmcz-runner-rkg64-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 9 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-29rb6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 10 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-2pvj8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 11 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-5ld6c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 12 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-5wf6r-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 13 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-6dhpf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 14 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-7lkk7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 15 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-8fglf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 16 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-9nwhb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 17 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-9zvv5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 18 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-fkjhh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 19 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-frlsh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 20 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-gf6hn-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 21 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-gwh6h-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 22 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-hf44c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 23 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-k6bcs-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 24 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-n2xmx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 25 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-pgt2v-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 26 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-pqtjk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 27 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-q5hxr-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 28 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-r82sj-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 29 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-rfmdb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 30 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-rwqh8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 31 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-s9pss-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 32 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-tbn44-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 33 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-xxl42-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 34 | sgl-project-sglang | linux-aarch64-a3-800t-2-cn12-001-9pgjb-runner-xzznh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 35 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-26r6s-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 36 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-4f9dl-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 37 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-4v8m9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 38 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-59xv9-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 39 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-7hpvv-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 40 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-bf8ms-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 41 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-bg87g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 42 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-dh58g-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 43 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-jgknk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 44 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-jgpjf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 45 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-jv28n-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 46 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-lhmf4-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 47 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-n4jhz-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 48 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-njjlk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 49 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-pd279-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 50 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-qxzjn-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 51 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-r4ndd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 52 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-s28gm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 53 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-s2czm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 54 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-t847b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 55 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-twfxf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 56 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-v4586-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 57 | sgl-project-sglang | linux-aarch64-a3-800t-4-cn12-001-75bp8-runner-vsv56-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`e745888b…` |
| 58 | ascend | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 59 | ascend | sgl-project-sglang-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 60 | ascend | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 61 | ascend | sglang-npu-sglang-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 62 | ascend-gha-runners | ascend-ci-share-ascend-gha-runners | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 63 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 64 | ascend-gha-runners | sgl-project-sglang-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 65 | ascend-gha-runners | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 66 | ascend-gha-runners | sglang-npu-sglang-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 67 | ascend-gha-runners-cn12-001 | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 68 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 69 | default | pvc-shared | Bound | 49.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 70 | monitoring | pvc-cache-cleanup-gy004-share | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 71 | ping1jing2 | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 72 | sfs-local-system | ascend-ci-share | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 73 | sfs-local-system | ascend-ci-share-pkking-sglang | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 74 | sfs-system | cleanup-sfs-turbo-ascend-ci-03 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 75 | sgl-kernel-npu | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 76 | sgl-project | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 77 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 78 | sgl-project-sglang | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 79 | sgl-project-sglang | sglang-shared-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.5 gy-005 — openmerlin-guiyang-005-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-005-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **47** 个

按 StorageClass：`csi-sfsturbo`×37，`sfsturbo-subpath-sc`×5，`squid-subpath-sc`×4，`csi-disk-topology`×1 ｜ 状态：Bound×47

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | ascend-pytorch | linux-aarch64-cpu-24-lql96-runner-tp2qx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`95a3d42c…` |
| 2 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`95a3d42c…` |
| 3 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`95a3d42c…` |
| 4 | smart-git-proxy | smart-git-proxy-mirrors | Bound | 500Gi | sfsturbo-subpath-sc | 共享`95a3d42c…` |
| 5 | vllm-project-vllm-ascend | linux-aarch64-a3-800t-0-g77hq-runner-gmbjk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`95a3d42c…` |
| 6 | squid | cache-squid-cache-0 | Bound | 200Gi | squid-subpath-sc | 共享`b46afb97…` |
| 7 | squid | cache-squid-cache-1 | Bound | 200Gi | squid-subpath-sc | 共享`b46afb97…` |
| 8 | squid | registry-cache-squid-cache-0 | Bound | 400Gi | squid-subpath-sc | 共享`b46afb97…` |
| 9 | squid | registry-cache-squid-cache-1 | Bound | 400Gi | squid-subpath-sc | 共享`b46afb97…` |
| 10 | monitoring | pvc-prometheus-server-0 | Bound | 400Gi | csi-disk-topology | 独立:disk |
| 11 | ascend | ascend-ray-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 12 | ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 13 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 14 | ascend-gha-runners | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 15 | ascend-gha-runners | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 16 | ascend-gha-runners | sync-guiyang-005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 17 | ascend-gha-runners | test-new | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 18 | ascend-gha-runners-cn12-001 | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 19 | ascend-gha-runners-cn12-001 | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 20 | ascend-pytorch | ascend-pytorch-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 21 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 22 | gdzhu01 | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 23 | gdzhu01 | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 24 | gdzhu01 | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 25 | monitoring | pvc-cache-cleanup-gy005-cidev | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 26 | monitoring | pvc-cache-cleanup-gy005-pytorch | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 27 | nv-action | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 28 | nv-action | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 29 | nv-action | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 30 | sfs-local-system | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 31 | tile-ai | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 32 | tile-ai | tile-ai-tilelang-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 33 | tile-ai-tilelang-mlir-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 34 | tile-ai-tilelang-mlir-ascend | tile-ai-tilelang-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 35 | triton-ascend | ascend-triton-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 36 | triton-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 37 | vllm-ascend-ci-dev-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 38 | vllm-ascend-ci-dev-vllm-ascend | vllm-ascend-ci-dev-vllm-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 39 | vllm-ascend-vllm-ascend-kimi-k3 | gy005-az5-vllm-ascend | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 40 | vllm-project | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 41 | vllm-project | gy005-az5-vllm-ascend | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 42 | vllm-project | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 43 | vllm-project | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 44 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 45 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 46 | xuedinge233-triton-ascend | ascend-triton-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 47 | xuedinge233-triton-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.6 gy-006 — openmerlin-guiyang-006-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-006-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-test` ｜ PVC 共 **58** 个

按 StorageClass：`sfsturbo-subpath-sc`×25，`csi-disk`×11，`csi-disk-topology`×8，`csi-sfsturbo`×7，`csi-disk-dss`×6，`-`×1 ｜ 状态：Bound×57，Pending×1

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | sfs-local-system | ascend-gha-runners-vllm-ascend-gy006 | Bound | 1.2Ti | - | 共享`45eb5e4c…` |
| 2 | argo | 68c3d707ca41441096025017b415b482-ci | Bound | 8Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 3 | argo | ascend-archive-ascendnpu-ir | Bound | 1Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 4 | argo | ascend-ascendnpu-ir | Bound | 8Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 5 | argo | test | Bound | 1Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 6 | argo | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 7 | ascend-gha-runners | ascend-gha-runners-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 8 | ascend-gha-runners | ascend-gha-runners-vllm-ascend-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 9 | ascend-gha-runners | sglang-npu-sglang-v3 | Bound | 600Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 10 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 11 | harbor | data-harbor-trivy-0 | Bound | 5Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 12 | harbor | data-harbor-trivy-1 | Bound | 5Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 13 | harbor | harbor-jobservice | Bound | 1Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 14 | harbor | harbor-registry | Bound | 1000Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 15 | mindstudio | pvc-mindstudio | Bound | 50Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 16 | monitoring | grafana-storage | Bound | 20Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 17 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 18 | nv-action | nv-action-vllm-benchmarks-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 19 | ragsdk | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 20 | smart-git-proxy | smart-git-proxy-mirrors | Bound | 500Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 21 | squid | cache-squid-cache-0 | Bound | 50Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 22 | squid | cache-squid-cache-1 | Bound | 50Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 23 | squid | registry-cache-squid-cache-0 | Bound | 200Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 24 | squid | registry-cache-squid-cache-1 | Bound | 200Gi | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 25 | vllm-ascend-vllm-ascend-kimi-k3 | gy006-vllm-ascend | Bound | 1.2Ti | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 26 | vllm-project | vllm-project-vllm-ascend-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc | 共享`45eb5e4c…` |
| 27 | arc-history | pod-history-pg-data | Bound | 20Gi | csi-disk | 独立:disk |
| 28 | milvus | data-my-release-etcd-0 | Bound | 10Gi | csi-disk | 独立:disk |
| 29 | milvus | data-my-release-etcd-1 | Bound | 10Gi | csi-disk | 独立:disk |
| 30 | milvus | data-my-release-etcd-2 | Bound | 10Gi | csi-disk | 独立:disk |
| 31 | milvus | export-my-release-minio-0 | Bound | 500Gi | csi-disk | 独立:disk |
| 32 | milvus | export-my-release-minio-1 | Bound | 500Gi | csi-disk | 独立:disk |
| 33 | milvus | export-my-release-minio-2 | Bound | 500Gi | csi-disk | 独立:disk |
| 34 | milvus | export-my-release-minio-3 | Bound | 500Gi | csi-disk | 独立:disk |
| 35 | milvus | my-release-milvus | Bound | 50Gi | csi-disk | 独立:disk |
| 36 | npu-exporter | prometheus | Bound | 100Gi | csi-disk | 独立:disk |
| 37 | vault | data-vault-0 | Bound | 10Gi | csi-disk | 独立:disk |
| 38 | default | agent-config-woodpecker-agent-0 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 39 | default | data-woodpecker-server-0 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 40 | karmada-system | etcd-data-ascend-ci-karmada-etcd-0 | Bound | 3Gi | csi-disk-dss | 独立:disk |
| 41 | woodpecker | agent-config-woodpecker-agent-0 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 42 | woodpecker | agent-config-woodpecker-agent-1 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 43 | woodpecker | data-woodpecker-server-0 | Bound | 10Gi | csi-disk-dss | 独立:disk |
| 44 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-0 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 45 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-1 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 46 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-2 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 47 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-0 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 48 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-1 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 49 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-2 | Bound | 300Gi | csi-disk-topology | 独立:disk |
| 50 | default | data-vault-0 | Pending | 10Gi | csi-disk-topology | 未绑定 |
| 51 | monitoring | pvc-prometheus-server-0 | Bound | 10Gi | csi-disk-topology | 独立:disk |
| 52 | arc-history | pod-history-data | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 53 | ascend-gha-runners | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 54 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 55 | cllouud | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | 独立:sfsturbo |
| 56 | cllouud | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 57 | nv-action | custom-index | Bound | 50Mi | csi-sfsturbo | 独立:sfsturbo |
| 58 | vllm-ascend | vllm-ascend-gy006 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.7 infra-gy-001 — ascend-infra-guiyang-cluster-001

kubeconfig: `~/.kube/configs/ascend-infra-guiyang-cluster-001-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **68** 个

按 StorageClass：`csi-sfsturbo`×35，`sfsturbo-subpath-sc`×15，`harbor-subpath-sc`×8，`csi-disk`×8，`csi-sfs`×1，`-`×1 ｜ 状态：Bound×68

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | harbor | data-harbor-trivy-0 | Bound | 5Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 2 | harbor | data-harbor-trivy-1 | Bound | 5Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 3 | harbor | harbor-jobservice | Bound | 1Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 4 | harbor | harbor-registry | Bound | 2Ti | harbor-subpath-sc | 共享`488cfc84…` |
| 5 | squid | cache-squid-cache-0 | Bound | 200Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 6 | squid | cache-squid-cache-1 | Bound | 200Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 7 | squid | registry-cache-squid-cache-0 | Bound | 200Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 8 | squid | registry-cache-squid-cache-1 | Bound | 200Gi | harbor-subpath-sc | 共享`488cfc84…` |
| 9 | argo | ascend-ascendnpu-ir | Bound | 1Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 10 | argo | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 11 | ascend-data-sync | testorg-testrepo-test15 | Bound | 10Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 12 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-4tq62-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 13 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-5wt5w-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 14 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-cs24b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 15 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-dbnw7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 16 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-dpzv7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 17 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-tt6jx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 18 | cosdt-ci-test | linux-aarch64-a2-1-6z4fn-runner-vpkrx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 19 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 20 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`d561f410…` |
| 21 | op-plugin | ascend-op-plugin | Bound | 100Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 22 | op-plugin | pvc-ascend-pytorch-for-lingqu | Bound | 100Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 23 | ragsdk | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc | 共享`d561f410…` |
| 24 | sfs-test | pvc-test-mount | Bound | 1.2Ti | - | 独立:- |
| 25 | milvus | data-my-release-etcd-0 | Bound | 10Gi | csi-disk | 独立:disk |
| 26 | milvus | data-my-release-etcd-1 | Bound | 10Gi | csi-disk | 独立:disk |
| 27 | milvus | data-my-release-etcd-2 | Bound | 10Gi | csi-disk | 独立:disk |
| 28 | milvus | export-my-release-minio-0 | Bound | 500Gi | csi-disk | 独立:disk |
| 29 | milvus | export-my-release-minio-1 | Bound | 500Gi | csi-disk | 独立:disk |
| 30 | milvus | export-my-release-minio-2 | Bound | 500Gi | csi-disk | 独立:disk |
| 31 | milvus | export-my-release-minio-3 | Bound | 500Gi | csi-disk | 独立:disk |
| 32 | milvus | my-release-milvus | Bound | 50Gi | csi-disk | 独立:disk |
| 33 | milvus | milvus-pvc | Bound | 10Gi | csi-sfs | 独立:nas |
| 34 | argo | pvc-computingactiontest-op-plugin-0731 | Bound | 200Gi | csi-sfsturbo | 独立:sfsturbo |
| 35 | argo | pvc-perform-compare | Bound | 200Gi | csi-sfsturbo | 独立:sfsturbo |
| 36 | argo | pvc-sharesfstest | Bound | 200Gi | csi-sfsturbo | 独立:sfsturbo |
| 37 | argo | pvc-testspeed-1 | Bound | 200Gi | csi-sfsturbo | 独立:sfsturbo |
| 38 | ascend-data-sync | ascend-data-root | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 39 | ascend-gha-runners-hk-001 | vllm-ascend-hk-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 40 | cann | pvc-cann | Bound | 200Gi | csi-sfsturbo | 独立:sfsturbo |
| 41 | cosdt-ci-test | cosdt-ci-test-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 42 | devin-dc-huang | devin-dc-huang-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 43 | drivingsdk | pvc-ascend-drivingsdk | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 44 | fsdpturbo | pvc-ascend-fsdpturbo | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 45 | indexsdk | pvc-ascend-indexsdk | Bound | 4.8Ti | csi-sfsturbo | 独立:sfsturbo |
| 46 | licy666 | licy666-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 47 | megatronadaptor | pvc-ascend-megatronadaptor | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 48 | memcache | pvc-ascend-memcache | Bound | 10Gi | csi-sfsturbo | 独立:sfsturbo |
| 49 | memfabric-hybrid | pvc-ascend-memfabric-hybrid | Bound | 10Gi | csi-sfsturbo | 独立:sfsturbo |
| 50 | mindspeed | pvc-ascend-mindspeed | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 51 | mindspeed-bridge | pcv-ascend-mindspeed-bridge | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 52 | mindspeed-llm | pvc-ascend-mindspeed-llm | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 53 | mindspeed-mm | pvc-ascend-mindspeed-mm | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 54 | mindspeed-ops | pvc-ascend-mindspeed-ops | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 55 | mindstudio | pvc-mindstudio | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 56 | multimodalsdk | pvc-ascend-multimodalsdk | Bound | 4.8Ti | csi-sfsturbo | 独立:sfsturbo |
| 57 | opensourceways | opensourceways-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 58 | ragsdk | pvc-ascend-ragsdk | Bound | 4.8Ti | csi-sfsturbo | 独立:sfsturbo |
| 59 | recsdk | pvc-ascend-recsdk | Bound | 4.8Ti | csi-sfsturbo | 独立:sfsturbo |
| 60 | sfs-local-mount | pvc-sfs-turbo-local-mount.cf5c6fef-ab67-11f1-b6fa-fa16412f71d0 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 61 | sfs-test | pvc-test-normal | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 62 | shared-sfs | pvc-shared-sfs-turbo | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 63 | slime-ascend | pvc-ascend-slime-ascend | Bound | 6Ti | csi-sfsturbo | 独立:sfsturbo |
| 64 | triton-ascend | triton-ascend-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 65 | verl-project-verl-omni | verl-project-verl-omni-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 66 | visionsdk | pvc-ascend-visionsdk | Bound | 20Gi | csi-sfsturbo | 独立:sfsturbo |
| 67 | vllm-ascend-vllm-ascend-recipes | vllm-ascend-vllm-ascend-recipes-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 68 | vllm-project | vllm-project-gy001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.8 aiframework — ascend-aiframework

kubeconfig: `~/.kube/configs/aiframework-kubeconfig.yaml` ｜ 区域 `cn-north-12` ｜ nginx 布局 `-new` ｜ PVC 共 **42** 个

按 StorageClass：`sfsturbo-subpath-sc`×21，`csi-sfsturbo`×20，`csi-disk-topology`×1 ｜ 状态：Bound×42

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | ascend-gha-runners | ascend-gha-runners-pytorch | Bound | 200Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 2 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-8wvwx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 3 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-dmsx8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 4 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-tjwpd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 5 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 6 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 7 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-5829p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 8 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-7dv2f-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 9 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-9l8fb-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 10 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-lztrf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 11 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-pphdw-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 12 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-rt2ld-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 13 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-xv7rf-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 14 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-xxcn8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 15 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-6v9z8-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 16 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-95t9q-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 17 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-fmgrd-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 18 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-kgv5p-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 19 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-rjvw5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 20 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-zk82c-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 21 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-8-cn12-001-xms7p-runner-pw8m2-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`ba20b346…` |
| 22 | monitoring | grafana-v10-pvc | Bound | 5Gi | csi-disk-topology | 独立:disk |
| 23 | alibaba-roll-liqo | alibaba-roll-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 24 | areal-project-areal | areal-project-areal-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 25 | areal-project-areal | areal-project-areal-shared-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 26 | ascend | ascend-pytorch-v1 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 27 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 28 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 29 | model-download | pvc-efs-test | Bound | 14.4Ti | csi-sfsturbo | 独立:sfsturbo |
| 30 | monitoring | pvc-cache-cleanup-areal | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 31 | monitoring | pvc-cache-cleanup-big | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 32 | monitoring | pvc-cache-cleanup-pytorch | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 33 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 34 | tile-ai-tilelang-mlir-ascend-liqo | tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 35 | triton-ascend-liqo | triton-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 36 | verl-project-liqo | verl-project-liqo-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 37 | verl-project-liqo | verl-project-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 38 | vllm-ascend-800i-aiframe | vllm-ascend-800i-aiframe | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 39 | vllm-ascend-vllm-ascend-recipes | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 40 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 41 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 42 | vllm-project-vllm-omni | vllm-project-vllm-omni-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.9 mind-third-ci — ascend-mind-third-ci（ArgoCD: hb-003-verl）

kubeconfig: `~/.kube/configs/ascend-mind-third-ci-kubeconfig.yaml` ｜ 区域 `cn-north-12` ｜ nginx 布局 `-new` ｜ PVC 共 **45** 个

按 StorageClass：`csi-sfsturbo`×24，`sfsturbo-subpath-sc`×21 ｜ 状态：Bound×45

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-rklhv-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 2 | ascend-pytorch | linux-aarch64-a3-800i-2-cn12-001-7msmr-runner-v56bh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 3 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-c4dkp-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 4 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-j6dx5-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 5 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-k668k-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 6 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-n9764-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 7 | ascend-pytorch | linux-aarch64-a3-800i-8-cn12-001-9hplt-runner-t8np7-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 8 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 9 | nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 10 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-5hrp2-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 11 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-96ztm-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 12 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-c7lzt-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 13 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-vg9hx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 14 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-vlgrx-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 15 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-2-cn12-001-tbq22-runner-zmf8k-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 16 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-gqhmh-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 17 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-k42d6-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 18 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-lz4fk-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 19 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-pss8b-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 20 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-q425t-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 21 | vllm-project-vllm-ascend | linux-aarch64-a3-800i-4-cn12-001-84qx8-runner-stbts-work | Bound | 64Gi | sfsturbo-subpath-sc | 共享`a8317f79…` |
| 22 | alibaba-roll-liqo | alibaba-roll-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 23 | areal-project-areal | areal-project-areal-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 24 | areal-project-areal | areal-project-areal-shared-v3 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 25 | ascend-gha-runners | verl-hb003 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 26 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 27 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 28 | default | sfs-root-probe | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 29 | model-download | pvc-efs-44t | Bound | 43.9Ti | csi-sfsturbo | 独立:sfsturbo |
| 30 | model-download | pvc-efs-test | Bound | 14.4Ti | csi-sfsturbo | 独立:sfsturbo |
| 31 | monitoring | pvc-cache-cleanup-dl | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 32 | monitoring | pvc-cache-cleanup-verl | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 33 | monitoring | pvc-cache-cleanup-vllm | Bound | 1Gi | csi-sfsturbo | 独立:sfsturbo |
| 34 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 35 | tile-ai-tilelang-mlir-ascend-liqo | tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 36 | triton-ascend-liqo | triton-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 37 | verl-project | verl-hb003 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 38 | verl-project-liqo | verl-project-liqo-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 39 | verl-project-liqo | verl-project-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 40 | verl-project-liqo | verl-src-old-data | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 41 | vllm-ascend-800i-mind | vllm-ascend-800i-mind-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 42 | vllm-ascend-vllm-ascend-recipes | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 43 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 44 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |
| 45 | vllm-project-vllm-omni | vllm-project-vllm-omni-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | 独立:sfsturbo |

### I.5.10 sh-001 — openmerlin-sh-001-cluster

kubeconfig: `~/.kube/configs/openmerlin-sh-001-cluster-kubeconfig` ｜ 区域 `-` ｜ nginx 布局 `-new (hostPath)` ｜ PVC 共 **0** 个

集群中无任何 PVC（工作负载走 hostPath / NFS 直挂，如 nginx 缓存 `/data/nginx-cache`）。

### I.5.11 sh-002 — sh-002

kubeconfig: `~/.kube/configs/sh-002-kubeconfig` ｜ 区域 `-` ｜ nginx 布局 `-new` ｜ PVC 共 **6** 个

按 StorageClass：`-`×5，`sfsturbo-subpath-sc`×1 ｜ 状态：Bound×5，Pending×1

| # | Namespace | PVC | Phase | 容量 | StorageClass | 底层 |
|---|---|---|---|---|---|---|
| 1 | ascend-gha-runners | vllm-ascend-share-pvc-test | Bound | 1.2Ti | - | 共享`179.60.1…` |
| 2 | ascend-pytorch | ascend-pytorch-share-pvc | Bound | 1.2Ti | - | 共享`179.60.1…` |
| 3 | sgl-kernel-npu | sgl-project-sgl-kernel-npu-share-pvc | Bound | 1.2Ti | - | 共享`179.60.1…` |
| 4 | sgl-project | sgl-project-sglang-share-pvc | Bound | 1.2Ti | - | 共享`179.60.1…` |
| 5 | triton-ascend | ascend-triton-ascend-share-pvc | Bound | 1.2Ti | - | 共享`179.60.1…` |
| 6 | nginx-pypi-cache | pypi-cache-data-volume | Pending | 1Ti | sfsturbo-subpath-sc | 未绑定 |

## I.6 采集方法（复现）

```bash
# 只读采集，以 hk-001 为例；其余集群换 KUBECONFIG 即可
export KUBECONFIG=~/.kube/configs/ascend-hk-001-cluster-kubeconfig.yaml
kubectl get pvc -A -o json > pvc.json
kubectl get pv -o json > pv.json
# 物理盘归组：同一 everest.io/volume-id 即同一块 SFS Turbo
jq -r '.items[]|select(.spec.csi.volumeAttributes["everest.io/volume-as"]=="subpath")|[.spec.csi.volumeAttributes["everest.io/volume-id"], .spec.claimRef.namespace+"/"+.spec.claimRef.name]|@tsv' pv.json | sort
# live max_size 核对
kubectl get deploy -n nginx-pypi-cache -o jsonpath='{.items[0].spec.template.spec.volumes[?(@.configMap)].configMap.name}'
kubectl get cm -n nginx-pypi-cache <CM名> -o json | jq -r '.data[]' | grep -oE 'keys_zone=\w+|max_size=\w+'
```

---

*Part I 生成：2026-09-18 ｜ issue [#2279](https://github.com/opensourceways/backlog/issues/2279) ｜ 全程只读，未修改任何集群对象*

# Part II：Ascend CI 各集群共享盘盘点（/root/.cache 目录用途）

> 更新时间：2026-09-14（当日 250 个 90 天未访问模型目录已标记，9-15 定时任务物理删除：cn12 66 个 ≈3.1 TiB、hk 91 个、gy003 93 个、gy004 0 个）。统计方式：在 monitoring 命名空间起一次性 Job 挂载各共享 PVC/NFS，对 top-level 目录执行 `du -sk`（NFS 全量遍历，数字为实际占用）。单位 GiB/TiB 为二进制。
> 用途判定依据：目录名 + runner/pod-template 环境变量（`MODELSCOPE_CACHE`、`HF_HOME`、`PIP_CACHE_DIR`、`ASCEND_WORK_PATH` 等）+ CI 脚本约定。标注 (?) 的为推断。

## 0. 总览：物理盘 → 挂载关系

| 集群 | 物理盘（SFS Turbo share / NFS）| export 子目录 | 谁在用它 | 清理器覆盖 |
|---|---|---|---|---|
| hk-001 | `24dd126e` | `/ascend-ci-share-nv-action-vllm-benchmarks` | **vllm-project runner `/root/.cache`**（PVC `vllm-project-hk001`）| mcc `/mnt/nvbench` |
| hk-001 | `24dd126e` | `/ascend-ci-share` | 通用根（几乎空）| mcc `/mnt/share` |
| hk-001 | `24dd126e` | `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` | ci-dev（几乎空）| mcc `/mnt/cidev` |
| hk-001 | `9c241417` | `/ascend-ci-share-pkking-sglang` | **sgl-project runner `/root/.cache`**（PVC `sgl-project-sglang-hk001`）| mcc `/mnt/sglang` |
| hk-001 | `d5b643e2` | `/ascend-ci-share` | **verl/RL 训练 CI** 缓存（`sfs-system/cleanup-sfs-turbo-for-ascend-verl-ci` 管）| mcc `/mnt/d5share` |
| cn12 | `37cbefa6` | `/ascend-ci-share` | **vllm + sgl runner `/root/.cache`**（cn12 上的 PVC 复用了 `gy005-az5-vllm-ascend-v2` 命名但指向本集群 `37cbefa6`，勿望文生义）| mcc `/mnt/share` |
| gy003 | `b46afb97` | `/ascend-ci-share-nv-action-vllm-benchmarks` | **gy003+gy005 vllm runner `/root/.cache`**（`gy003-az5-vllm-ascend`、`gy005-az5-vllm-ascend{,-v2}` 同 export）| gy003 mcc `/mnt/b46nv` |
| gy003/005 | `23021270` | `/ascend-ci-share-nv-action-vllm-benchmarks` | 旧 benchmarks 盘（大量个人目录，含镜像副本）| gy003 mcc `/mnt/230nv` |
| gy003 | `39a33a00` | `/ascend-ci-share` | 旧 sglang 性能测试盘（基本停用）| gy003 mcc `/mnt/ci39a` |
| gy005 | `23021270` | `/ascend-ci-share-pkking-pytorch` | torch-npu 构建 ccache | gy005 mcc `/mnt/pytorch` |
| gy005 | `23021270` | `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` | ci-dev plog 日志 | gy005 mcc `/mnt/cidev` |
| gy004 | `1b51fb58` | `/ascend-ci-share-pkking-sglang` | **sgl runner `/root/.cache`**（`sglang-guiyang004`）| gy004 mcc `/mnt/share` |
| gy006 | - | - | 无共享缓存盘（runner 不挂 `/root/.cache` 共享卷）| - |
| sh-001 | NFS `suzblue.server:/share`（lab 物理 NAS）| 整盘（hostPath）| **vllm-project runner `/root/.cache` = 整块 `/mnt/share`**（317T，与人共用）| ❌ 无清理器 |
| sh-001 | NFS `suzblue.server:/weight` | 整盘 | 模型权重（82T 已用，当前 pod-template 未挂载，历史遗留）| ❌ 无清理器 |

**要点**
- `model-cache-cleanup` cronjob（每集群每周二 19:00 CST，90 天未访问先标 `.deleteable` 一周后物理删）的 MOUNTS 与上表一一对应；gy005 的模型盘由 gy003 清单代管（同 export 不双跑），gy006/sh-001 **没有**清理器。
- 各盘占用大头都是 `modelscope/` + `huggingface/` 模型缓存；日志类（`log/`、`ascend-logs/`）在 cn12 也到了 TiB 级，是清理器覆盖不到的（只清模型 marker 路径）。

## 1. 香港 hk-001

### 1.1 `24dd126e:nv-action-vllm-benchmarks` — vllm-project runner `/root/.cache`（合计 23.1 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 20.2 TiB | ModelScope 模型下载缓存（清理器主战场）|
| huggingface/ | 2.6 TiB | HF 模型缓存 |
| weights/ | 162 GiB | 手工放置的模型权重 |
| uv/ | 97 GiB | uv 包缓存 |
| ascend-ci-share-nv-action-vllm-benchmarks/ | 76 GiB | 异常嵌套目录 (?)（历史上误把 share 根挂成子目录产生的副本）|
| vllm/ | 28 GiB | vLLM torch.compile 缓存 |
| ascend-logs/ | 11 GiB | CI 测试日志收集 |
| wxs/、mnj/、pta/、wl/、lwj/ | 约 1.1 TiB | 个人目录（未归属）|
| pip/ | 3.5 GiB | pip wheel 缓存 |
| evalscope/ | 2.1 GiB | EvalScope 评测产物 |
| datasets/ | 1.2 GiB | HF datasets 缓存 |
| go-build/ | 0.98 GiB | Go 构建缓存 |
| main2main-pre-commit(-x86_64)/、pre-commit/ | 约 2.3 GiB | lint/nightly pre-commit hook 缓存 |
| whisper/ | 0.45 GiB | whisper 模型下载 |
| miniconda/、virtualenv/ | 0.24 GiB | Python 环境 |
| buildkit/、ccache/、torch_extensions/、tvm-ffi/、pybind11/ 等 | 均 <1 GiB | 各类编译缓存 |
| 其余 30+ 个小目录 | 零散 | 工具缓存（opencode、claude、YAPF、matplotlib…）、输出（upload_perf、benchmark_results、profile_output、nightly_bisect）、个人 |

### 1.2 `9c241417:pkking-sglang` — sgl-project runner `/root/.cache`（合计 8.3 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 8.0 TiB | 模型缓存 |
| huggingface/ | 136 GiB | HF 缓存 |
| z30065769/、wl/、d00662834/、l30079981/、dzc/、memelin/、swx1199799/、c30044170/ | 约 118 GiB | 个人目录 |
| log/ | 50 GiB | 运行日志 |
| sglang/ | 13 GiB | SGLang 缓存 |
| pip/ | 11 GiB | pip 缓存 |
| tests/ | 5 GiB | 测试产物 |
| ccache/、uv/、torch_extensions/、tvm-ffi/、outlines/、YAPF/ | 均小 | 编译/工具缓存 |
| ascend_all_logs/ | 7 MiB | SGLang 全量日志 |

### 1.3 `d5b643e2:/ascend-ci-share` — verl/RL CI 缓存（合计 528 GiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| huggingface/ | 265 GiB | RL 训练用模型缓存 |
| models/ | 158 GiB | RL 模型权重 |
| offload_cache/ | 61 GiB | verl 训练 offload |
| uv/、pip/、modelscope/ | 27 / 9 / 7 GiB | 包缓存 |
| datasets/ | 219 MiB | 训练数据集 |
| go-build/ | 1.3 GiB | Go 缓存 |
| 根目录 grpo_*.log / ppo_*.log | 几百 KB | RL 测试日志散落根目录（垃圾）|
| lockers/、.lock/、swift-web-ui/ | ~0 | 锁文件/残留 |

### 1.4 其余：`24dd126e:/ascend-ci-share`（仅 huggingface 379 MiB）、`/ascend-ci-share-vllm-ascend-ci-dev-...`（仅 uv 28 KiB）——基本空置。

## 2. CN12（37cbefa6:/ascend-ci-share — vllm+sgl 共用 `/root/.cache`，合计 59.9 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 55.9 TiB | 模型缓存（**今天已标 3.1 TiB / 66 个 `.deleteable`，明晚删除**）|
| huggingface/ | 2.4 TiB | HF 缓存 |
| log/ | 812 GiB | 运行日志/plog（清理器不覆盖，需另行治理）|
| tests/ | 619 GiB | 测试产物/数据（清理器不覆盖）|
| vllm/ | 66 GiB | torch.compile 缓存 |
| areal-ci-tmp/ | 57 GiB | AReaL RL CI 临时（清理器不覆盖）|
| ascend-logs/ | 53 GiB | CI 测试日志 |
| uv/、pip/、pip-cache/ | 30+17 GiB | 包缓存 |
| sglang/ | 14 GiB | SGLang 缓存 |
| ccache/ | 5 GiB | 编译缓存 |
| pre-commit/ | 557 MiB | hook 缓存 |
| whisper/、datasets/、buildkit/、sgl_diffusion/、torch/、torch_extensions/、sgl_eval/、virtualenv/、deepep/ | 均 <500 MiB | 各类缓存/产物 |
| 个人目录（d00662834 等）| ~0 | 空 |

> CN12 盘已写入约 60 TiB（声明 1200Gi 的 SFS Turbo 按量爆发）。模型占比 97%，日志+测试产物约 1.5 TiB 属于清理盲区。

## 3. 贵阳 003 / 005

### 3.1 `b46afb97:nv-action-vllm-benchmarks` — **gy003+gy005 的 runner `/root/.cache`**，合计 41.9 TiB

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 35.0 TiB | 模型缓存（gy003/gy005 vllm CI 共用；**今天已标 93 个，明晚删**）|
| gdy2/ | 1.6 TiB | 个人目录 |
| lbw/ | 1.3 TiB | 个人目录 |
| log/ | 1.1 TiB | 运行日志（清理盲区）|
| openmind/ | 1.0 TiB | 项目/个人数据目录 (?) |
| huggingface/ | 0.9 TiB | HF 缓存 |
| weights/ | 432 GiB | 模型权重 |
| vllm/ | 227 GiB | torch.compile 缓存 |
| ascend-logs/ | 190 GiB | CI 日志 |
| lby_vllm/、zym/、lwm_omni/、zxy/、cmh/、lby_qwen/、wxs/、puccinialin/、gdy/ 等 | 约 180 GiB | 个人目录 |
| vllm-omni/ | 62 GiB | 缓存/产物 |
| uv/ | 22 GiB、pip_cache/ 3.6 GiB、pre-commit/ 2.5 GiB、ccache/ 0.6 GiB | 包/编译缓存 |
| bazel/ 11 GiB、bazelisk/、mooncake-wheelhouse-ascend/ 0.6 GiB | | triton/mooncake 构建缓存 |
| tmp/ | 4.1 GiB | 临时 |
| 其余工具/环境小目录 | | conda、vscode-cpptools、jedi、opencode、gh、claude… |

### 3.2 `23021270:nv-action-vllm-benchmarks` — 旧 benchmarks 盘，合计 32.6 TiB

结构与 3.1 高度重合（gdy2/lbw/openmind/weights 数值几乎一致，**疑似整盘迁移/镜像的旧副本，可评估退役**）：modelscope 25.7 TiB、huggingface 2.2 TiB、gdy2 1.6 TiB、lbw 1.3 TiB、openmind 1.0 TiB、weights 432 GiB、vllm 68 GiB、vllm-omni 62 GiB、vime-checkpoints 57 GiB（个人训练 checkpoint）、其余个人目录约 2.5 TiB。根目录还有大量 `_*.py` 调试脚本散落（2025-2026 遗留）。

### 3.3 `39a33a00:/ascend-ci-share` — 旧 sglang 测试盘，合计 123 GiB
vllm-ascend/ 117 GiB（旧构建缓存）、ShareGPT_Vicuna_unfiltered 4.0 GiB、SmolLM2-135M 1.8 GiB、sccache/ccache 缓存、9 月 report 目录若干。**基本停用，可整体清理。**

### 3.4 gy005 自有两个挂载
`23021270:pkking-pytorch`：仅 ccache 4.3 GiB（torch-npu C++ 编译缓存）。
`23021270:vllm-ascend-ci-dev`：仅 log 264 KiB（plog）。

## 4. 贵阳 004（1b51fb58:pkking-sglang — sgl runner `/root/.cache`，合计 26.7 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 24.1 TiB | 模型缓存（本轮 90 天无 stale，清理器空转）|
| KVTC/ | 1.0 TiB | KV 压缩项目数据（个人/项目）|
| log/ | 806 GiB | 运行日志（清理盲区）|
| tests/ | 566 GiB | 测试产物（清理盲区）|
| huggingface/ | 214 GiB | HF 缓存 |
| d00662834/ | 29 GiB | 个人目录（工号）|
| pip/ | 18 GiB | pip 缓存 |
| sglang/、uv/、ccache/ | 6.9 / 5.0 / 4.8 GiB | SGLang 缓存、包/编译缓存 |
| aisbench/ | 2.5 GiB | 项目数据 |
| multi-node-test/ 144 MiB、coverage_data/ 87 MiB、sgl_diffusion/ 86 MiB、sgl_eval/ 15 MiB、pre-commit/ 221 MiB | | 测试/评测产物、hook 缓存 |
| torch_extensions/、deepep/、tvm-ffi/、black/、YAPF/、outlines/、matplotlib/、deep_gemm/、runs/ | ≈0 | 工具缓存 |
| 根目录散落 | | README.md、mp3/mp4 演示文件（Trump_WEF、bird_song、jobs*.mp4）等与 CI 无关；有 .gitattributes 痕迹，疑似仓库直接 clone 在盘根 |

## 5. 贵阳 006
无共享缓存卷（runner 不挂 `/root/.cache`），不参与模型清理体系。

## 6. 上海 sh-001（NFS `suzblue.server:/share` 317T/用 41T — runner `/root/.cache` = 整盘）

**特殊情况**：runner 的 `/root/.cache` 是 hostPath 整盘 `/mnt/share`（317T 物理 NAS），CI 缓存与实验室人员个人目录混在一起。CI 相关 top-level 目录 du 结果：

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 11.9 TiB | 模型缓存（**无清理器覆盖**）|
| huggingface/ | 1.5 TiB | HF 缓存 |
| weight/ | 1.1 TiB | 模型权重 |
| ascend-ci/ | 525 GiB | CI 工作产物 |
| conda_envs/ | 30 GiB | conda 环境 |
| log/ | 16 GiB | 日志 |
| vllm/ | 10.8 GiB | compile 缓存 |
| vllm-ascend/ | 1.3 GiB | 早期项目级缓存（uv 1.3 GiB 在此）|
| go-build/ 160 MiB、weights/ 181 MiB、ascend-logs/、virtualenv/、torch_extensions/、YAPF/、tests/、pip/、uv/ | 均 ≤200 MiB | 缓存杂项（pip/uv 实际只用了 KB 级——job 容器 PIP_CACHE_DIR 被重定向到 /tmp）|
| 其余 ~25 TiB | | 实验室个人目录（c008xxxx、l00xxxxx、w00xxxxx 工号目录、人名目录）、autotest/CANN 包、数百个 `postStart-*.log` 碎片等 |

另有 `suzblue.server:/weight`（358T/用 82T）整盘模型权重库（DeepSeek/Qwen 等），当前 vllm-project pod-template 已不再挂载它（改从 `/root/.cache/weight` 取），属历史遗留。

## 7. 清理盲区与建议

1. **日志/产物类无清理**：cn12 `log/` 812 GiB + `tests/` 619 GiB、b46nv `log/` 1.1 TiB、sglang 盘 `log/` 50 GiB —— model-cache-cleanup 只扫模型 marker 路径。建议增加按天数的日志轮转 cronjob。
2. **sh-001 无清理器**：11.9 TiB modelscope 无 TTL 治理；且 `/root/.cache` 直挂整块 317T 人用 NAS，建议为 CI 单独划 export 子目录（如 `/mnt/share/ci`）。
3. **230nv 旧盘疑似 b46nv 镜像**：gdy2/lbw/openmind/weights 尺寸逐项一致，若确认为迁移遗留，退役可释放 ~32 TiB。
4. **个人目录占比**：b46nv/230nv 个人目录合计约 2.5-3 TiB/盘；hk nvbench 约 1 TiB。建议在盘根 README/工单推动清理，或纳入 cleanup 的 `KEEP_REGEX` 白名单外的二级策略。
5. **gy005 runner PVC 命名误导**（`gy005-az5-vllm-ascend-v2` 实际 export 与 gy003 同名 share），跨集群同盘访问是刻意设计（见 ascend-ci-deployment 注释），排查时勿被名字迷惑。
