# Ascend CI 共享磁盘 / PVC 审计（完整版）

本文两部分：**Part I** 为 2026-09-18 只读 kubectl 采集的 PVC/物理盘归属盘点与 nginx max_size 生效核对（backlog#2279 跟进）；**Part II** 为 2026-09-14 一次性 Job `du` 实测的各共享盘目录用途/占用盘点（原文保留）。两部分的物理盘可互相对照，如 hk-001 `d5b643e2`（Part I 44-PVC 共享盘）= Part II 的 verl/RL CI 缓存盘，gy-005 `b46afb97`（squid-subpath）= Part II 的 gy003/005 共用 benchmarks 大盘。

> 关联 issue：[opensourceways/backlog#2279](https://github.com/opensourceways/backlog/issues/2279)（nginx-pypi-cache 各集群 max_size 总和超物理卷容量，跟进生效与共享占用治理），专项 [#2171](https://github.com/opensourceways/backlog/issues/2171) 共享磁盘优化专项，关联 [#2173](https://github.com/opensourceways/backlog/issues/2173) 共享盘文件来源分析。
>
> **数据采集**：2026-09-18，全程只读（`kubectl get pvc/pv/sc`、读取 live ConfigMap），未对集群做任何修改。
> 物理盘归属识别方法：Huawei everest CSI 的 PV `spec.csi.volumeAttributes["everest.io/volume-id"]`——同一个 `volume-id` 下的所有 PVC **共享同一块 SFS Turbo 物理卷**（subpath 动态供应，PV 申请量 ≠ 实际占用，也不受 PV 容量约束）。

---

## I.1 结论速览

1. **一个集群一块“大共享盘”**：各集群几乎所有 `sfsturbo-subpath-sc` PVC 都挂在**同一块**物理 SFS Turbo 上（gy-005 / infra-gy-001 另有一块独立的 squid/harbor 共享盘）；**nginx-pypi-cache、git-cdn、harbor、squid、runner 工作盘（-work）、模型/数据集缓存等所有租户都挤在同一块盘上**。cn12-001 上该共享盘挂了 **220 个 PVC**，hk-001 挂 44 个，gy-006 挂 26 个（含 1 个静态 NFS 直挂）（即 issue 中说的 421G 现场）。
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

## I.3 共享物理盘清单（每块盘一行，ID 全列）

同一 `volume-id` = 同一块物理 SFS Turbo / NFS。成员构成两类：
- **runner 工作卷**（PVC 名以 `-work` 结尾）：ARC ephemeral runner 随 job 创建/销毁的工作盘（64Gi 占位），数量大但生命周期短；
- **持久卷**（其余）：nginx/git-cdn/squid/harbor/共享缓存等，真正决定盘的长期占用。

`Σ申请` 为 requests 之和——subpath 模式下只是占位可超卖，不代表实际占用；真实占用见 Part II 的 du 实测。

| 集群 | SC | volume-id（物理盘 ID） | PVC 总数 | 其中工作卷 | 持久卷清单（ns/name·容量） | Σ申请 | nginx | 用途说明 |
|---|---|---|---|---|---|---|---|---|
| hk-001 | sfsturbo-subpath-sc | `d5b643e2-b838-4109-9ba5-f762a99daee9` | 44 | 40 | nginx-pypi-cache/pypi-cache-data-volume；smart-git-proxy/smart-git-proxy-mirrors；squid/registry-cache-pvc；squid/squid-cache-pvc | 4.6Ti | ✅ | 集群唯一大共享盘；与 Part II 的 hk `d5b643e2`（verl/RL CI 缓存盘）同盘 |
| cn12-001 | sfsturbo-subpath-sc | `665a3415-80ff-4388-b452-773448c8a74f` | 220 | 212 | buildkitd/test；git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume；squid/cache-squid-cache-0；squid/cache-squid-cache-1；squid/registry-cache-squid-cache-0；squid/registry-cache-squid-cache-1；usernamefull/usernamefull-roll-cn12-001 | 16.8Ti | ✅ | 全体系最大共享盘；含 gy005 命名的 vllm/triton 共享缓存 PVC（跨集群同盘设计，见 Part II 要点5） |
| gy-003 | sfsturbo-subpath-sc | `0ca03ada-9d51-4b2c-83a4-f03f079a6963` | 10 | 8 | git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume | 1.4Ti | ✅ | 310P vllm runner 工作卷 + 缓存卷 |
| gy-004 | sfsturbo-subpath-sc | `e745888b-ec2c-49d6-b16a-b0372402d843` | 57 | 55 | git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume | 4.6Ti | ✅ | SGLang runner 工作卷 + 缓存卷 |
| gy-005 | sfsturbo-subpath-sc | `95a3d42c-f6ed-41e2-91d0-c3a113b10792` | 5 | 2 | git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume；smart-git-proxy/smart-git-proxy-mirrors | 1.8Ti | ✅ | vllm/pytorch CI 缓存卷（runner 工作卷另在 csi-sfsturbo 独立盘） |
| gy-005 | squid-subpath-sc | `b46afb97-6954-11f1-af0f-fa16412f71d0` | 4 | 0 | squid/cache-squid-cache-0；squid/cache-squid-cache-1；squid/registry-cache-squid-cache-0；squid/registry-cache-squid-cache-1 | 1.2Ti | — | squid 代理缓存；与 Part II `b46afb97`（gy003/005 runner `/root/.cache` 大盘）同盘 |
| gy-006 | -/sfsturbo-subpath-sc | `45eb5e4c-ea7c-4ae2-a0c1-f84867ce74e1` | 26 | 0 | argo/68c3d707ca41441096025017b415b482-ci；argo/ascend-archive-ascendnpu-ir；argo/ascend-ascendnpu-ir；argo/test；argo/testorg-testrepo-test15；ascend-gha-runners/ascend-gha-runners-gy006；ascend-gha-runners/ascend-gha-runners-vllm-ascend-gy006；ascend-gha-runners/sglang-npu-sglang-v3；git-cdn/git-cdn-workdir；harbor/data-harbor-trivy-0；harbor/data-harbor-trivy-1；harbor/harbor-jobservice；harbor/harbor-registry；mindstudio/pvc-mindstudio；monitoring/grafana-storage；nginx-pypi-cache/pypi-cache-data-volume；nv-action/nv-action-vllm-benchmarks-gy006；ragsdk/testorg-testrepo-test15；sfs-local-system/ascend-gha-runners-vllm-ascend-gy006；smart-git-proxy/smart-git-proxy-mirrors；squid/cache-squid-cache-0；squid/cache-squid-cache-1；squid/registry-cache-squid-cache-0；squid/registry-cache-squid-cache-1；vllm-ascend-vllm-ascend-kimi-k3/gy006-vllm-ascend；vllm-project/vllm-project-vllm-ascend-gy006 | 10.9Ti | ✅ | issue 421G 现场盘：harbor/squid/grafana/argo/共享缓存混住，另有 1 个静态 NFS PV 直挂同盘（sfs-local-system） |
| infra-gy-001 | sfsturbo-subpath-sc | `d561f410-2692-4a18-9c3f-bbfcd3b6012f` | 15 | 7 | argo/ascend-ascendnpu-ir；argo/testorg-testrepo-test15；ascend-data-sync/testorg-testrepo-test15；git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume；op-plugin/ascend-op-plugin；op-plugin/pvc-ascend-pytorch-for-lingqu；ragsdk/testorg-testrepo-test15 | 1.8Ti | ✅ | cosdt/argo/op-plugin CI 混用 |
| infra-gy-001 | harbor-subpath-sc | `488cfc84-5378-11f1-8401-fa16412f71d0` | 8 | 0 | harbor/data-harbor-trivy-0；harbor/data-harbor-trivy-1；harbor/harbor-jobservice；harbor/harbor-registry；squid/cache-squid-cache-0；squid/cache-squid-cache-1；squid/registry-cache-squid-cache-0；squid/registry-cache-squid-cache-1 | 2.8Ti | — | harbor 镜像仓库专用共享盘（registry 申请 2Ti 为占位） |
| aiframework | sfsturbo-subpath-sc | `ba20b346-a7bd-48aa-9a41-3dbf0c7c03a6` | 21 | 18 | ascend-gha-runners/ascend-gha-runners-pytorch；git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume | 2.5Ti | ✅ | a3-800i runner 工作卷 + pytorch 共享缓存 |
| mind-third-ci | sfsturbo-subpath-sc | `a8317f79-8762-4a9c-a18c-ebae7ce2ad0e` | 21 | 19 | git-cdn/git-cdn-workdir；nginx-pypi-cache/pypi-cache-data-volume | 2.4Ti | ✅ | a3-800i runner 工作卷 + 缓存卷 |
| sh-002 | - | `179.60.12.2` | 5 | 0 | ascend-gha-runners/vllm-ascend-share-pvc-test；ascend-pytorch/ascend-pytorch-share-pvc；sgl-kernel-npu/sgl-project-sgl-kernel-npu-share-pvc；sgl-project/sgl-project-sglang-share-pvc；triton-ascend/ascend-triton-ascend-share-pvc | 5.9Ti | — | 静态 NFS（无 SC、预先绑定 PV）：5 个 CI 的 share-pvc 各 1.2Ti 占位 |

其余 PVC 均为**每 PVC 独占**的动态卷（`csi-sfsturbo`=独立 SFS Turbo、`csi-disk*`=EVS 盘、`csi-sfs`=SFS），不存在跨租户共享问题，逐行见 I.5 各集群“独占卷”表。

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
- [ ] gy-006 共享盘 421G 实际占用治理（harbor registry / nv-action / kimi-k3 等）——见 issue 验收项 3 与 Part II。

## I.5 各集群 PVC 清单

共享盘成员只列总量与持久卷（`-work` 工作卷仅计数，构成见 I.3 表），独占卷逐行列出。

### I.5.1 hk-001 — ascend-hk-001-cluster

kubeconfig: `~/.kube/configs/ascend-hk-001-cluster-kubeconfig.yaml` ｜ 区域 `ap-southeast-1` ｜ nginx 布局 `-new` ｜ PVC 共 **93** 个

状态：Bound×93

**共享盘 `d5b643e2…`：44 个 PVC**（runner 工作卷 `-work`×40，合计 2.5Ti 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |
| smart-git-proxy | smart-git-proxy-mirrors | Bound | 500Gi | sfsturbo-subpath-sc |
| squid | registry-cache-pvc | Bound | 400Gi | sfsturbo-subpath-sc |
| squid | squid-cache-pvc | Bound | 200Gi | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：49 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | vault | data-vault-0 | Bound | 10Gi | csi-disk-dss | disk |
| 2 | monitoring | pvc-prometheus-server-0 | Bound | 200Gi | csi-disk-topology | disk |
| 3 | ascend | ascend-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 4 | ascend | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 5 | ascend-docs | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 6 | ascend-gha-runners | ascend-gha-runners-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 7 | ascend-gha-runners | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 8 | ascend-gha-runners | pvc-hk001-sglang | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 9 | ascend-gha-runners | pvc-hk001-vllm | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 10 | ascend-gha-runners | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 11 | ascend-gha-runners-hk-001 | vllm-ascend-hk-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 12 | codemayq-transformers | codemayq-transformers-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 13 | cosdt | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 14 | fla-org-flash-linear-attention | fla-org-flash-linear-attention-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 15 | ganding-rlinf | ganding-rlinf-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 16 | gdzhu01 | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 17 | goalina-transformers | goalina-transformers-a2-hk-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 18 | hiyouga | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | linkedin | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | modelscope | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 21 | monitoring | pvc-cache-cleanup-hk-cidev | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 22 | monitoring | pvc-cache-cleanup-hk-d5share | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 23 | monitoring | pvc-cache-cleanup-hk-nvbench | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 24 | monitoring | pvc-cache-cleanup-hk-sglang | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 25 | monitoring | pvc-cache-cleanup-hk-share | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 26 | nginx-test | test | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 27 | nv-action | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 28 | pt-ecosystem-flash-linear-attention-dev | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 29 | pytorch-fdn | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 30 | sfs-local-mount | pvc-sfs-turbo-local-mount.c5803d39-6bf4-46dd-b6ad-983e0631cb8e | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 31 | sfs-local-system | ascend-ci-share-pkking-sglang | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 32 | sfs-local-system | ascend-gha-runners-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 33 | sfs-system | cleanup-sfs-turbo-for-ascend-verl-ci | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 34 | sgl-kernel-npu | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 35 | sgl-project | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 36 | sgl-project-sglang-omni | sgl-project-sglang-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 37 | triton-ascend | ascend-triton-ascend-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 38 | usernamefull-transformers-ci | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 39 | verl-project-uni-agent | verl-uni-agent-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 40 | verl-project-verl-speco | verl-verl-speco-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 41 | vllm-ascend-ci-dev-vllm-ascend | vllm-ascend-ci-dev-vllm-ascend-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 42 | vllm-ascend-main2main-automator | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 43 | vllm-ascend-vllm-ascend-kimi-k3 | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 44 | vllm-project | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 45 | vllm-project-vllm-ascend | vllm-ascend-sz-lab | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 46 | volcengine | hk001-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 47 | xuedinge233 | vllm-project-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 48 | xuedinge233-triton-ascend | triton-ascend-hk001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 49 | git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc | sfsturbo |

### I.5.2 cn12-001 — ascend-cn12-001-cluster

kubeconfig: `~/.kube/configs/ascend-cn12-001-cluster-kubeconfig.yaml` ｜ 区域 `cn-north-12` ｜ nginx 布局 `v2` ｜ PVC 共 **271** 个

状态：Bound×271

**共享盘 `665a3415…`：220 个 PVC**（runner 工作卷 `-work`×212，合计 13.2Ti 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| buildkitd | test | Bound | 10Gi | sfsturbo-subpath-sc |
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |
| squid | cache-squid-cache-0 | Bound | 200Gi | sfsturbo-subpath-sc |
| squid | cache-squid-cache-1 | Bound | 200Gi | sfsturbo-subpath-sc |
| squid | registry-cache-squid-cache-0 | Bound | 400Gi | sfsturbo-subpath-sc |
| squid | registry-cache-squid-cache-1 | Bound | 400Gi | sfsturbo-subpath-sc |
| usernamefull | usernamefull-roll-cn12-001 | Bound | 1.2Ti | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：51 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | vault | data-vault-0 | Bound | 10Gi | csi-disk-dss | disk |
| 2 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk |
| 3 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk |
| 4 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk |
| 5 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-3 | Bound | 300Gi | csi-disk-topology | disk |
| 6 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk |
| 7 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk |
| 8 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk |
| 9 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-3 | Bound | 300Gi | csi-disk-topology | disk |
| 10 | alibaba-roll | alibaba-roll-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 11 | alibaba-roll-liqo | alibaba-roll-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 12 | areal-project-areal | areal-project-areal-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 13 | areal-project-areal | areal-project-areal-shared-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 14 | ascend | ascend-sglang-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 15 | ascend | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 16 | ascend-docs | ascend-docs-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 17 | ascend-gha-runners | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 18 | ascend-gha-runners | omni-hb003 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | ascend-gha-runners | sglang-public-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | ascend-gha-runners-gy004 | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 21 | ascend-gha-runners-gy005 | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 22 | ascend-gha-runners-gy005 | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 23 | ascend-gha-runners-gy006 | ascend-gha-runners-vllm-ascend-gy006 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 24 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 25 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 26 | liqo-test | liqo-test-share | Bound | 14.4Ti | csi-sfsturbo | sfsturbo |
| 27 | monitoring | pvc-cache-cleanup-cn12-share | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 28 | nv-action | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 29 | sfs-local-mount | pvc-sfs-turbo-local-mount.8258ca0d-8dce-4a35-8802-79d10e0f8f9f | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 30 | sfs-local-system | ascend-ci-share | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 31 | sfs-local-system | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 32 | sgl-kernel-npu | sglang-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 33 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 34 | sgl-project-sglang | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 35 | sgl-project-sglang | sglang-shared-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 36 | tecjesh-triton-ascend | triton-ascend-cn12-001-pvc | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 37 | tile-ai-tilelang-mlir-ascend | tile-ai-tilelang-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 38 | tile-ai-tilelang-mlir-ascend-liqo | tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 39 | triton-ascend | ascend-triton-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 40 | triton-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 41 | triton-ascend-liqo | triton-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 42 | verl-project-liqo | verl-project-liqo-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 43 | verl-project-liqo | verl-project-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 44 | vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 45 | vllm-ascend-vllm-ascend-recipes | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 46 | vllm-project | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 47 | vllm-project | test | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 48 | vllm-project | vllm-omni-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 49 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 50 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 51 | vllm-project-vllm-omni | vllm-project-vllm-omni-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.3 gy-003 — openmerlin-guiyang-003-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-003-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **52** 个

状态：Bound×52

**共享盘 `0ca03ada…`：10 个 PVC**（runner 工作卷 `-work`×8，合计 256Gi 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：42 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | coder | coder-00eb6ddf-5562-4d7c-8553-101763fbd4a6-home | Bound | 1000Gi | csi-disk | disk |
| 2 | coder | coder-1de3c53e-25bd-4657-a9de-7aa7bf158bc9-home | Bound | 100Gi | csi-disk | disk |
| 3 | coder | coder-324724f5-0445-42ee-b11b-3db3ab7bf650-home | Bound | 100Gi | csi-disk | disk |
| 4 | coder | coder-5c8888bf-8728-4413-815b-4fd17ee5f147-home | Bound | 100Gi | csi-disk | disk |
| 5 | coder | coder-8418dc3c-d6da-4810-8e39-53833602e9be-home | Bound | 100Gi | csi-disk | disk |
| 6 | coder | coder-95f186a6-0474-40cb-a29d-948b4365d02e-home | Bound | 100Gi | csi-disk | disk |
| 7 | coder | coder-9c83e2c0-5daf-4c24-a530-c63dbb974c8e-home | Bound | 100Gi | csi-disk | disk |
| 8 | coder | coder-c64e61cc-5e5e-47c3-bbae-00781f9df657-home | Bound | 100Gi | csi-disk | disk |
| 9 | coder | coder-cece37ec-2241-4ba3-840a-0e4a608b8b50-home | Bound | 200Gi | csi-disk | disk |
| 10 | npu-exporter | prometheus | Bound | 10Gi | csi-disk | disk |
| 11 | monitoring | grafana-pvc | Bound | 105Gi | csi-disk-topology | disk |
| 12 | cllouud | test | Bound | 1Gi | csi-sfs | nas |
| 13 | arc-systems | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 14 | ascend | ascend-ci-share-ascend-ascend-ci | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 15 | ascend | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 16 | ascend-gha-runners | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 17 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 18 | ascend-gha-runners | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | ascend-gha-runners | nv-action-vllm-benchmarks-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | cllouud | ascend-ci-hook-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 21 | cllouud | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 22 | cllouud | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 23 | cllouud | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 24 | coder | sfs-turbo-coder | Bound | 2.4Ti | csi-sfsturbo | sfsturbo |
| 25 | cosdt | ascend-ci-share-cosdt | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 26 | cosdt | cosdt-store | Bound | 100Mi | csi-sfsturbo | sfsturbo |
| 27 | cosdt | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 28 | listener-pod-persistence | prometheus-pvc | Bound | 200Gi | csi-sfsturbo | sfsturbo |
| 29 | model-download | model-download-cache | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 30 | monitoring | pvc-cache-cleanup-gy003-230nv | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 31 | monitoring | pvc-cache-cleanup-gy003-39a | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 32 | monitoring | pvc-cache-cleanup-gy003-b46nv | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 33 | nv-action | ascend-ci-hook-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 34 | nv-action | ascend-ci-share-nv-action-vllm-benchmarks | Bound | 500Gi | csi-sfsturbo | sfsturbo |
| 35 | nv-action | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 36 | nv-action | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 37 | pytorch-fdn | ascendci-pytorch-fdn-oota | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 38 | pytorch-fdn | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 39 | sfs-system | cleanup-sfs-turbo-ascend-ci-02 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 40 | vllm-ascend-ci-dev-vllm-ascend | vllm-ascend-ci-dev-vllm-ascend-gy003 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 41 | vllm-project | gy003-az5-vllm-ascend | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 42 | vllm-project | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.4 gy-004 — openmerlin-guiyang-004-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-004-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **79** 个

状态：Bound×79

**共享盘 `e745888b…`：57 个 PVC**（runner 工作卷 `-work`×55，合计 3.4Ti 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：22 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | ascend | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 2 | ascend | sgl-project-sglang-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 3 | ascend | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 4 | ascend | sglang-npu-sglang-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 5 | ascend-gha-runners | ascend-ci-share-ascend-gha-runners | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 6 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 7 | ascend-gha-runners | sgl-project-sglang-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 8 | ascend-gha-runners | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 9 | ascend-gha-runners | sglang-npu-sglang-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 10 | ascend-gha-runners-cn12-001 | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 11 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 12 | default | pvc-shared | Bound | 49.2Ti | csi-sfsturbo | sfsturbo |
| 13 | monitoring | pvc-cache-cleanup-gy004-share | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 14 | ping1jing2 | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 15 | sfs-local-system | ascend-ci-share | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 16 | sfs-local-system | ascend-ci-share-pkking-sglang | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 17 | sfs-system | cleanup-sfs-turbo-ascend-ci-03 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 18 | sgl-kernel-npu | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | sgl-project | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 21 | sgl-project-sglang | sglang-guiyang004 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 22 | sgl-project-sglang | sglang-shared-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.5 gy-005 — openmerlin-guiyang-005-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-005-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **47** 个

状态：Bound×47

**共享盘 `95a3d42c…`：5 个 PVC**（runner 工作卷 `-work`×2，合计 128Gi 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |
| smart-git-proxy | smart-git-proxy-mirrors | Bound | 500Gi | sfsturbo-subpath-sc |

**共享盘 `b46afb97…`：4 个 PVC**（runner 工作卷 `-work`×0，合计 0B 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| squid | cache-squid-cache-0 | Bound | 200Gi | squid-subpath-sc |
| squid | cache-squid-cache-1 | Bound | 200Gi | squid-subpath-sc |
| squid | registry-cache-squid-cache-0 | Bound | 400Gi | squid-subpath-sc |
| squid | registry-cache-squid-cache-1 | Bound | 400Gi | squid-subpath-sc |

**独占卷（每 PVC 一块物理盘）：38 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | monitoring | pvc-prometheus-server-0 | Bound | 400Gi | csi-disk-topology | disk |
| 2 | ascend | ascend-ray-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 3 | ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 4 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 5 | ascend-gha-runners | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 6 | ascend-gha-runners | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 7 | ascend-gha-runners | sync-guiyang-005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 8 | ascend-gha-runners | test-new | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 9 | ascend-gha-runners-cn12-001 | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 10 | ascend-gha-runners-cn12-001 | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 11 | ascend-pytorch | ascend-pytorch-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 12 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 13 | gdzhu01 | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 14 | gdzhu01 | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 15 | gdzhu01 | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 16 | monitoring | pvc-cache-cleanup-gy005-cidev | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 17 | monitoring | pvc-cache-cleanup-gy005-pytorch | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 18 | nv-action | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 19 | nv-action | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | nv-action | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 21 | sfs-local-system | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 22 | tile-ai | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 23 | tile-ai | tile-ai-tilelang-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 24 | tile-ai-tilelang-mlir-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 25 | tile-ai-tilelang-mlir-ascend | tile-ai-tilelang-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 26 | triton-ascend | ascend-triton-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 27 | triton-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 28 | vllm-ascend-ci-dev-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 29 | vllm-ascend-ci-dev-vllm-ascend | vllm-ascend-ci-dev-vllm-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 30 | vllm-ascend-vllm-ascend-kimi-k3 | gy005-az5-vllm-ascend | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 31 | vllm-project | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 32 | vllm-project | gy005-az5-vllm-ascend | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 33 | vllm-project | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 34 | vllm-project | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 35 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 36 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 37 | xuedinge233-triton-ascend | ascend-triton-ascend-gy005 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 38 | xuedinge233-triton-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.6 gy-006 — openmerlin-guiyang-006-cluster

kubeconfig: `~/.kube/configs/openmerlin-guiyang-006-cluster-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-test` ｜ PVC 共 **58** 个

状态：Bound×57，Pending×1

**共享盘 `45eb5e4c…`：26 个 PVC**（runner 工作卷 `-work`×0，合计 0B 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| argo | 68c3d707ca41441096025017b415b482-ci | Bound | 8Gi | sfsturbo-subpath-sc |
| argo | ascend-archive-ascendnpu-ir | Bound | 1Gi | sfsturbo-subpath-sc |
| argo | ascend-ascendnpu-ir | Bound | 8Gi | sfsturbo-subpath-sc |
| argo | test | Bound | 1Gi | sfsturbo-subpath-sc |
| argo | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc |
| ascend-gha-runners | ascend-gha-runners-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc |
| ascend-gha-runners | ascend-gha-runners-vllm-ascend-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc |
| ascend-gha-runners | sglang-npu-sglang-v3 | Bound | 600Gi | sfsturbo-subpath-sc |
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| harbor | data-harbor-trivy-0 | Bound | 5Gi | sfsturbo-subpath-sc |
| harbor | data-harbor-trivy-1 | Bound | 5Gi | sfsturbo-subpath-sc |
| harbor | harbor-jobservice | Bound | 1Gi | sfsturbo-subpath-sc |
| harbor | harbor-registry | Bound | 1000Gi | sfsturbo-subpath-sc |
| mindstudio | pvc-mindstudio | Bound | 50Gi | sfsturbo-subpath-sc |
| monitoring | grafana-storage | Bound | 20Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |
| nv-action | nv-action-vllm-benchmarks-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc |
| ragsdk | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc |
| sfs-local-system | ascend-gha-runners-vllm-ascend-gy006 | Bound | 1.2Ti | - |
| smart-git-proxy | smart-git-proxy-mirrors | Bound | 500Gi | sfsturbo-subpath-sc |
| squid | cache-squid-cache-0 | Bound | 50Gi | sfsturbo-subpath-sc |
| squid | cache-squid-cache-1 | Bound | 50Gi | sfsturbo-subpath-sc |
| squid | registry-cache-squid-cache-0 | Bound | 200Gi | sfsturbo-subpath-sc |
| squid | registry-cache-squid-cache-1 | Bound | 200Gi | sfsturbo-subpath-sc |
| vllm-ascend-vllm-ascend-kimi-k3 | gy006-vllm-ascend | Bound | 1.2Ti | sfsturbo-subpath-sc |
| vllm-project | vllm-project-vllm-ascend-gy006 | Bound | 1.2Ti | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：32 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | arc-history | pod-history-pg-data | Bound | 20Gi | csi-disk | disk |
| 2 | milvus | data-my-release-etcd-0 | Bound | 10Gi | csi-disk | disk |
| 3 | milvus | data-my-release-etcd-1 | Bound | 10Gi | csi-disk | disk |
| 4 | milvus | data-my-release-etcd-2 | Bound | 10Gi | csi-disk | disk |
| 5 | milvus | export-my-release-minio-0 | Bound | 500Gi | csi-disk | disk |
| 6 | milvus | export-my-release-minio-1 | Bound | 500Gi | csi-disk | disk |
| 7 | milvus | export-my-release-minio-2 | Bound | 500Gi | csi-disk | disk |
| 8 | milvus | export-my-release-minio-3 | Bound | 500Gi | csi-disk | disk |
| 9 | milvus | my-release-milvus | Bound | 50Gi | csi-disk | disk |
| 10 | npu-exporter | prometheus | Bound | 100Gi | csi-disk | disk |
| 11 | vault | data-vault-0 | Bound | 10Gi | csi-disk | disk |
| 12 | default | agent-config-woodpecker-agent-0 | Bound | 10Gi | csi-disk-dss | disk |
| 13 | default | data-woodpecker-server-0 | Bound | 10Gi | csi-disk-dss | disk |
| 14 | karmada-system | etcd-data-ascend-ci-karmada-etcd-0 | Bound | 3Gi | csi-disk-dss | disk |
| 15 | woodpecker | agent-config-woodpecker-agent-0 | Bound | 10Gi | csi-disk-dss | disk |
| 16 | woodpecker | agent-config-woodpecker-agent-1 | Bound | 10Gi | csi-disk-dss | disk |
| 17 | woodpecker | data-woodpecker-server-0 | Bound | 10Gi | csi-disk-dss | disk |
| 18 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk |
| 19 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk |
| 20 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk |
| 21 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk |
| 22 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk |
| 23 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk |
| 24 | default | data-vault-0 | Pending | 10Gi | csi-disk-topology | 未绑定 |
| 25 | monitoring | pvc-prometheus-server-0 | Bound | 10Gi | csi-disk-topology | disk |
| 26 | arc-history | pod-history-data | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 27 | ascend-gha-runners | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 28 | ascend-gha-runners | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 29 | cllouud | ascend-ci-share | Bound | 100Gi | csi-sfsturbo | sfsturbo |
| 30 | cllouud | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 31 | nv-action | custom-index | Bound | 50Mi | csi-sfsturbo | sfsturbo |
| 32 | vllm-ascend | vllm-ascend-gy006 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.7 infra-gy-001 — ascend-infra-guiyang-cluster-001

kubeconfig: `~/.kube/configs/ascend-infra-guiyang-cluster-001-kubeconfig.yaml` ｜ 区域 `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC 共 **68** 个

状态：Bound×68

**共享盘 `d561f410…`：15 个 PVC**（runner 工作卷 `-work`×7，合计 448Gi 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| argo | ascend-ascendnpu-ir | Bound | 1Gi | sfsturbo-subpath-sc |
| argo | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc |
| ascend-data-sync | testorg-testrepo-test15 | Bound | 10Gi | sfsturbo-subpath-sc |
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |
| op-plugin | ascend-op-plugin | Bound | 100Gi | sfsturbo-subpath-sc |
| op-plugin | pvc-ascend-pytorch-for-lingqu | Bound | 100Gi | sfsturbo-subpath-sc |
| ragsdk | testorg-testrepo-test15 | Bound | 1Gi | sfsturbo-subpath-sc |

**共享盘 `488cfc84…`：8 个 PVC**（runner 工作卷 `-work`×0，合计 0B 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| harbor | data-harbor-trivy-0 | Bound | 5Gi | harbor-subpath-sc |
| harbor | data-harbor-trivy-1 | Bound | 5Gi | harbor-subpath-sc |
| harbor | harbor-jobservice | Bound | 1Gi | harbor-subpath-sc |
| harbor | harbor-registry | Bound | 2Ti | harbor-subpath-sc |
| squid | cache-squid-cache-0 | Bound | 200Gi | harbor-subpath-sc |
| squid | cache-squid-cache-1 | Bound | 200Gi | harbor-subpath-sc |
| squid | registry-cache-squid-cache-0 | Bound | 200Gi | harbor-subpath-sc |
| squid | registry-cache-squid-cache-1 | Bound | 200Gi | harbor-subpath-sc |

**独占卷（每 PVC 一块物理盘）：45 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | sfs-test | pvc-test-mount | Bound | 1.2Ti | - | - |
| 2 | milvus | data-my-release-etcd-0 | Bound | 10Gi | csi-disk | disk |
| 3 | milvus | data-my-release-etcd-1 | Bound | 10Gi | csi-disk | disk |
| 4 | milvus | data-my-release-etcd-2 | Bound | 10Gi | csi-disk | disk |
| 5 | milvus | export-my-release-minio-0 | Bound | 500Gi | csi-disk | disk |
| 6 | milvus | export-my-release-minio-1 | Bound | 500Gi | csi-disk | disk |
| 7 | milvus | export-my-release-minio-2 | Bound | 500Gi | csi-disk | disk |
| 8 | milvus | export-my-release-minio-3 | Bound | 500Gi | csi-disk | disk |
| 9 | milvus | my-release-milvus | Bound | 50Gi | csi-disk | disk |
| 10 | milvus | milvus-pvc | Bound | 10Gi | csi-sfs | nas |
| 11 | argo | pvc-computingactiontest-op-plugin-0731 | Bound | 200Gi | csi-sfsturbo | sfsturbo |
| 12 | argo | pvc-perform-compare | Bound | 200Gi | csi-sfsturbo | sfsturbo |
| 13 | argo | pvc-sharesfstest | Bound | 200Gi | csi-sfsturbo | sfsturbo |
| 14 | argo | pvc-testspeed-1 | Bound | 200Gi | csi-sfsturbo | sfsturbo |
| 15 | ascend-data-sync | ascend-data-root | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 16 | ascend-gha-runners-hk-001 | vllm-ascend-hk-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 17 | cann | pvc-cann | Bound | 200Gi | csi-sfsturbo | sfsturbo |
| 18 | cosdt-ci-test | cosdt-ci-test-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | devin-dc-huang | devin-dc-huang-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | drivingsdk | pvc-ascend-drivingsdk | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 21 | fsdpturbo | pvc-ascend-fsdpturbo | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 22 | indexsdk | pvc-ascend-indexsdk | Bound | 4.8Ti | csi-sfsturbo | sfsturbo |
| 23 | licy666 | licy666-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 24 | megatronadaptor | pvc-ascend-megatronadaptor | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 25 | memcache | pvc-ascend-memcache | Bound | 10Gi | csi-sfsturbo | sfsturbo |
| 26 | memfabric-hybrid | pvc-ascend-memfabric-hybrid | Bound | 10Gi | csi-sfsturbo | sfsturbo |
| 27 | mindspeed | pvc-ascend-mindspeed | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 28 | mindspeed-bridge | pcv-ascend-mindspeed-bridge | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 29 | mindspeed-llm | pvc-ascend-mindspeed-llm | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 30 | mindspeed-mm | pvc-ascend-mindspeed-mm | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 31 | mindspeed-ops | pvc-ascend-mindspeed-ops | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 32 | mindstudio | pvc-mindstudio | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 33 | multimodalsdk | pvc-ascend-multimodalsdk | Bound | 4.8Ti | csi-sfsturbo | sfsturbo |
| 34 | opensourceways | opensourceways-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 35 | ragsdk | pvc-ascend-ragsdk | Bound | 4.8Ti | csi-sfsturbo | sfsturbo |
| 36 | recsdk | pvc-ascend-recsdk | Bound | 4.8Ti | csi-sfsturbo | sfsturbo |
| 37 | sfs-local-mount | pvc-sfs-turbo-local-mount.cf5c6fef-ab67-11f1-b6fa-fa16412f71d0 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 38 | sfs-test | pvc-test-normal | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 39 | shared-sfs | pvc-shared-sfs-turbo | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 40 | slime-ascend | pvc-ascend-slime-ascend | Bound | 6Ti | csi-sfsturbo | sfsturbo |
| 41 | triton-ascend | triton-ascend-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 42 | verl-project-verl-omni | verl-project-verl-omni-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 43 | visionsdk | pvc-ascend-visionsdk | Bound | 20Gi | csi-sfsturbo | sfsturbo |
| 44 | vllm-ascend-vllm-ascend-recipes | vllm-ascend-vllm-ascend-recipes-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 45 | vllm-project | vllm-project-gy001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.8 aiframework — ascend-aiframework

kubeconfig: `~/.kube/configs/aiframework-kubeconfig.yaml` ｜ 区域 `cn-north-12` ｜ nginx 布局 `-new` ｜ PVC 共 **42** 个

状态：Bound×42

**共享盘 `ba20b346…`：21 个 PVC**（runner 工作卷 `-work`×18，合计 1.1Ti 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| ascend-gha-runners | ascend-gha-runners-pytorch | Bound | 200Gi | sfsturbo-subpath-sc |
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：21 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | monitoring | grafana-v10-pvc | Bound | 5Gi | csi-disk-topology | disk |
| 2 | alibaba-roll-liqo | alibaba-roll-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 3 | areal-project-areal | areal-project-areal-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 4 | areal-project-areal | areal-project-areal-shared-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 5 | ascend | ascend-pytorch-v1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 6 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 7 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 8 | model-download | pvc-efs-test | Bound | 14.4Ti | csi-sfsturbo | sfsturbo |
| 9 | monitoring | pvc-cache-cleanup-areal | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 10 | monitoring | pvc-cache-cleanup-big | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 11 | monitoring | pvc-cache-cleanup-pytorch | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 12 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 13 | tile-ai-tilelang-mlir-ascend-liqo | tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 14 | triton-ascend-liqo | triton-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 15 | verl-project-liqo | verl-project-liqo-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 16 | verl-project-liqo | verl-project-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 17 | vllm-ascend-800i-aiframe | vllm-ascend-800i-aiframe | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 18 | vllm-ascend-vllm-ascend-recipes | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 21 | vllm-project-vllm-omni | vllm-project-vllm-omni-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.9 mind-third-ci — ascend-mind-third-ci（ArgoCD: hb-003-verl）

kubeconfig: `~/.kube/configs/ascend-mind-third-ci-kubeconfig.yaml` ｜ 区域 `cn-north-12` ｜ nginx 布局 `-new` ｜ PVC 共 **45** 个

状态：Bound×45

**共享盘 `a8317f79…`：21 个 PVC**（runner 工作卷 `-work`×19，合计 1.2Ti 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| git-cdn | git-cdn-workdir | Bound | 200Gi | sfsturbo-subpath-sc |
| nginx-pypi-cache | pypi-cache-data-volume | Bound | 1Ti | sfsturbo-subpath-sc |

**独占卷（每 PVC 一块物理盘）：24 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | alibaba-roll-liqo | alibaba-roll-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 2 | areal-project-areal | areal-project-areal-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 3 | areal-project-areal | areal-project-areal-shared-v3 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 4 | ascend-gha-runners | verl-hb003 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 5 | ascend-pytorch | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 6 | ascend-sglang | ascend-sglang-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 7 | default | sfs-root-probe | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 8 | model-download | pvc-efs-44t | Bound | 43.9Ti | csi-sfsturbo | sfsturbo |
| 9 | model-download | pvc-efs-test | Bound | 14.4Ti | csi-sfsturbo | sfsturbo |
| 10 | monitoring | pvc-cache-cleanup-dl | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 11 | monitoring | pvc-cache-cleanup-verl | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 12 | monitoring | pvc-cache-cleanup-vllm | Bound | 1Gi | csi-sfsturbo | sfsturbo |
| 13 | sgl-project-sgl-kernel-npu | sgl-project-sgl-kernel-npu-liqo-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 14 | tile-ai-tilelang-mlir-ascend-liqo | tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 15 | triton-ascend-liqo | triton-ascend-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 16 | verl-project | verl-hb003 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 17 | verl-project-liqo | verl-project-liqo-cn12-001 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 18 | verl-project-liqo | verl-project-liqo-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 19 | verl-project-liqo | verl-src-old-data | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 20 | vllm-ascend-800i-mind | vllm-ascend-800i-mind-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 21 | vllm-ascend-vllm-ascend-recipes | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 22 | vllm-project-vllm-ascend | gy005-az5-vllm-ascend-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 23 | vllm-project-vllm-ascend | nv-action-vllm-benchmarks-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |
| 24 | vllm-project-vllm-omni | vllm-project-vllm-omni-cn12-001-v2 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo |

### I.5.10 sh-001 — openmerlin-sh-001-cluster

kubeconfig: `~/.kube/configs/openmerlin-sh-001-cluster-kubeconfig` ｜ 区域 `-` ｜ nginx 布局 `-new (hostPath)` ｜ PVC 共 **0** 个

集群中无任何 PVC（工作负载走 hostPath / NFS 直挂，如 nginx 缓存 `/data/nginx-cache`）。

### I.5.11 sh-002 — sh-002

kubeconfig: `~/.kube/configs/sh-002-kubeconfig` ｜ 区域 `-` ｜ nginx 布局 `-new` ｜ PVC 共 **6** 个

状态：Bound×5，Pending×1

**共享盘 `179.60.1…`：5 个 PVC**（runner 工作卷 `-work`×0，合计 0B 占位）

| Namespace | 持久 PVC | Phase | 容量 | SC |
|---|---|---|---|---|
| ascend-gha-runners | vllm-ascend-share-pvc-test | Bound | 1.2Ti | - |
| ascend-pytorch | ascend-pytorch-share-pvc | Bound | 1.2Ti | - |
| sgl-kernel-npu | sgl-project-sgl-kernel-npu-share-pvc | Bound | 1.2Ti | - |
| sgl-project | sgl-project-sglang-share-pvc | Bound | 1.2Ti | - |
| triton-ascend | ascend-triton-ascend-share-pvc | Bound | 1.2Ti | - |

**独占卷（每 PVC 一块物理盘）：1 个**

| # | Namespace | PVC | Phase | 容量 | StorageClass | 类型 |
|---|---|---|---|---|---|---|
| 1 | nginx-pypi-cache | pypi-cache-data-volume | Pending | 1Ti | sfsturbo-subpath-sc | 未绑定 |

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
