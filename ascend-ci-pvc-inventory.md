# Ascend CI 共享盘 / PVC 清单（2026-09-18，backlog#2279）

> 关联 issue：[#2279](https://github.com/opensourceways/backlog/issues/2279)（nginx max_size 超物理卷容量，跟进收紧生效与共享占用治理）｜ 专项 [#2171](https://github.com/opensourceways/backlog/issues/2171) ｜ 来源分析 [#2173](https://github.com/opensourceways/backlog/issues/2173)。
> 各共享盘**实际用了什么、用了多少**（du 实测）见同仓库 [`ascend-ci-shared-disk-audit.md`](ascend-ci-shared-disk-audit.md)（2026-09-14 盘点）。
>
> 采集：2026-09-18，全程只读（`kubectl get pvc/pv/sc` + 读 live CM）。盘归组依据：PV `spec.csi.volumeAttributes` 的 `everest.io/sfsturbo-share-id`（absolute-path 挂法）/ `everest.io/volume-id`（subpath 挂法）/ `nfs.server`——**同一 ID = 同一块物理盘**，与 PV/PVC 名无关。

## 1. 结论速览

- **27 块共享盘**（≥2 个 PV 同 share-id），共承载 **723 个 PV**；其余 ~100 个 PV 为每 PVC 独立盘（动态 csi-sfsturbo/csi-disk，无 share 复用）。
- **跨集群同盘**（同 UUID 出现在多集群，排查时极易被 PV 名误导）：`39a33a00`（gy003/004/005/006 四集群）、`b46afb97`（gy003/004/005）、`23021270`（gy003/005）、`0ca03ada`（gy003←gy004 1 PV）。
- 每个集群基本是 **1 块“集群大共享盘”**（nginx-pypi-cache 就挂在这块上）+ 1~2 块 runner `/root/.cache` 模型缓存大盘（absolute-path，同一 export 被 N 个 ns 的同名 PVC 挂用）。**nginx 写爆 = 同卷全租户遭殃**，这就是 #2279 的根因。
- #1695 收紧已全部生效（-new=400G、gy006 -test=50G）；但 **cn12-001（v2 目录）与 sh-002 仍 1480G 未收紧**；**PR #1706 拟把 -new 升到 450G（+crates 50G），gy-005 那块 500G 盘（`95a3d42c`，同盘还有 git-cdn/smart-git-proxy）将只剩 ~50G 余量，建议评审压回 ≤400G 或给 gy-005 单独 overlay**。
- gy-006 `45eb5e4c`（500G 已用 421G=85%）即 issue 现场；旧 1480G CM 残留未清。
- 盘容量/用量已用主监控 `shared_disk_*` 补齐 18/27 块（cronjob 每 10min 拨测 + >90% 告警）；**9 块真空**（IP host 漏发现 ×3 含 gy005/gy006 两块关键盘、infra-gy 集群无上报 ×5、挂载失败 ×2），详见 §2 末「监控覆盖情况」。

## 2. 全部共享盘总表（盘 → 集群 / 仓库 / 大小 / 分配）

- 挂法：`subpath`=每 PVC 一个随机子目录（SC 动态）；`absolute`=固定 export 子目录（多个同名 PVC 挂**同一目录**，即共享缓存盘）；`static`=手工 NFS PV。
- 排序：按集群归组（hk-001→cn12-001→gy-003…→sh-002），跨集群共用的盘排在主用（PV 最多）集群下，其余集群见“关联集群”列。
- 大小/已用来自主监控中心 `shared_disk_*`（cronjob 拨测，2026-09-18 快照）；`*`= k8s/监控均不可见，取 issue 2026-09-17 人工实测。告警线：>90% 5m critical（SharedDiskHighUsage）。

| 物理盘 ID | 关联集群（PV 数） | 挂法 | 盘大小 / 已用（监控实时） | 监控 | 盘下空间分配与用途 |
|---|---|---|---|---|---|
| `d5b643e2-b838-4109-9ba5-f762a99daee9` | hk-001×58 | subpath×44、absolute×14 | 6.0TiB / 用 553GiB | ok（9%） | hk 大共享盘：verl/RL CI 缓存（absolute）+ nginx/squid/smart-git-proxy/runner 工作卷（subpath）。subpath 44 目录：runner 工作卷×40（64Gi 占位，随 job 建删）；持久卷 hk-001:nginx-pypi-cache/pypi-cache-data-volume（1Ti）、hk-001:smart-git-proxy/smart-git-proxy-mirrors（500Gi）、hk-001:squid/registry-cache-pvc（400Gi）、hk-001:squid/squid-cache-pvc（200Gi）；export `/ascend-ci-share` ×11 PV（hk-001:monitoring、hk-001:verl-project-uni-agent、hk-001:hiyouga、hk-001:ascend-docs、hk-001:modelscope 等11方）；export `/` ×2 PV（hk-001:nginx-test、hk-001:sfs-system）；export `/git-cdn-workdir` ×1 PV（hk-001:git-cdn） |
| `24dd126e-0461-4ecf-986a-d022ade265b8` | hk-001×24 | absolute×24 | 27.8TiB / 用 21.1TiB | ok（76%） | hk nv-action benchmarks 大盘：vllm-project runner `/root/.cache`（23.1TiB），十余个 ns 挂同一 export。export `/ascend-ci-share-nv-action-vllm-benchmarks` ×17 PV（hk-001:ascend-gha-runners×2、hk-001:monitoring、hk-001:nv-action、hk-001:linkedin、hk-001:xuedinge233-triton-ascend 等16方）；export `/ascend-ci-share` ×5 PV（hk-001:monitoring、hk-001:ganding-rlinf、hk-001:codemayq-transformers、hk-001:fla-org-flash-linear-attention、hk-001:goalina-transformers）；export `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` ×2 PV（hk-001:monitoring、hk-001:vllm-ascend-ci-dev-vllm-ascend） |
| `9c241417-584d-403f-9e8f-dab73b5fc66b` | hk-001×8 | absolute×8 | 9.8TiB / 用 8.9TiB | ok（91%⚠） | hk pkking-sglang 大盘：sgl runner `/root/.cache`（8.3TiB）。export `/ascend-ci-share-pkking-sglang` ×8 PV（hk-001:ascend-gha-runners×2、hk-001:monitoring、hk-001:sgl-project、hk-001:sgl-kernel-npu、hk-001:sfs-local-system 等7方） |
| `665a3415-80ff-4388-b452-773448c8a74f` | cn12-001×220 | subpath×220 | 2.5TiB / 用 1.3TiB | ok（55%） | cn12 大共享盘：nginx-pypi-cache + git-cdn + squid + 212 个 runner 工作卷 + triton/sgl 共享缓存（含 gy005 命名的 PVC，跨集群同盘设计）。subpath 220 目录：runner 工作卷×212（64Gi 占位，随 job 建删）；持久卷 cn12-001:buildkitd/test（10Gi）、cn12-001:git-cdn/git-cdn-workdir（200Gi）、cn12-001:nginx-pypi-cache/pypi-cache-data-volume（1Ti）、cn12-001:squid/cache-squid-cache-1（200Gi）、cn12-001:squid/registry-cache-squid-cache-0（400Gi）、cn12-001:squid/cache-squid-cache-0（200Gi）、cn12-001:squid/registry-cache-squid-cache-1（400Gi）、cn12-001:usernamefull/usernamefull-roll-cn12-001（1.2Ti） |
| `37cbefa6-f10c-47e8-a99a-f483887611ef` | cn12-001×41 | absolute×41 | 77TiB(爆发) / 用 73.9TiB | ok（96%⚠） | cn12 runner `/root/.cache`（vllm+sgl 共用），41 个同名 PVC 各 ns 挂同一 export；模型缓存主盘。export `/ascend-ci-share` ×39 PV（cn12-001:ascend-gha-runners×3、cn12-001:vllm-project-vllm-ascend×2、cn12-001:triton-ascend×2、cn12-001:ascend×2、cn12-001:verl-project-liqo×2 等28方）；export `/` ×2 PV（cn12-001:vllm-project、cn12-001:liqo-test） |
| `39a33a00-3be8-4345-8079-63cf23a44a88` | gy-003×18、gy-006×7、gy-005×4、gy-004×3 | absolute×32 | 1.2TiB / 用 136GiB | ok（11%） | 旧 sglang 测试盘，现被 gy003/004/005/006 **四集群**当共享缓存盘复用。export `/custom-index` ×15 PV（gy-003:cllouud、gy-003:ascend-gha-runners、gy-003:ascend、gy-003:cosdt、gy-003:nv-action 等15方）；export `/ascend-ci-share` ×7 PV（gy-003:monitoring、gy-003:ascend-gha-runners、gy-003:cllouud、gy-003:arc-systems、gy-006:cllouud 等7方）；export `/ascend-ci-hook-index` ×2 PV（gy-003:nv-action、gy-003:cllouud）；export `/ascend-ci-share-cosdt` ×1 PV（gy-003:cosdt）；export `/cosdt/cosdt-store` ×1 PV（gy-003:cosdt）；export `/ascend-ci-share-ascend-ascend-ci` ×1 PV（gy-003:ascend）；export `/prometheus-pvc` ×1 PV（gy-003:listener-pod-persistence）；export `/ascendci-pytorch-fdn-oota` ×1 PV（gy-003:pytorch-fdn）；export `/ascend-ci-share-nv-action-vllm-benchmarks` ×1 PV（gy-003:nv-action）；export `/ascend-ci-share-ascend-gha-runners` ×1 PV（gy-004:ascend-gha-runners）；export `/pod-history` ×1 PV（gy-006:arc-history） |
| `0ca03ada-9d51-4b2c-83a4-f03f079a6963` | gy-003×12、gy-004×1 | subpath×10、absolute×3 | 1.2TiB / 用 49GiB | ok（4%） | gy003 大共享盘：nginx + git-cdn + 310P vllm runner 工作卷；gy004 有 1 PV 引用。subpath 10 目录：runner 工作卷×8（64Gi 占位，随 job 建删）；持久卷 gy-003:git-cdn/git-cdn-workdir（200Gi）、gy-003:nginx-pypi-cache/pypi-cache-data-volume（1Ti）；export `/` ×3 PV（gy-003:nginx-pypi-cache、gy-003:sfs-system、gy-004:sfs-system）；⚠ 孤儿 PV ×2：gy-003:nginx-pypi-cache/sfs-turbo-pypi-cache-data-volume（Released）、gy-004:sfs-system/cleanup-sfs-turbo-ascend-ci-02（Released） |
| `e745888b-ec2c-49d6-b16a-b0372402d843` | gy-004×58 | subpath×57、absolute×1 | 1.2TiB / 用 25GiB | ok（2%） | gy004 大共享盘：SGLang runner 工作卷×55 + nginx + git-cdn。subpath 57 目录：runner 工作卷×55（64Gi 占位，随 job 建删）；持久卷 gy-004:git-cdn/git-cdn-workdir（200Gi）、gy-004:nginx-pypi-cache/pypi-cache-data-volume（1Ti）；export `/` ×1 PV（gy-004:sfs-system） |
| `1b51fb58-ed37-47bb-995d-52a1fcbb1f43` | gy-004×17 | absolute×17 | 37.1TiB / 用 29.6TiB | ok（80%） | gy004 pkking-sglang 大盘：sgl runner `/root/.cache`（26.7TiB）。export `/ascend-ci-share-pkking-sglang` ×17 PV（gy-004:ascend×3、gy-004:ascend-gha-runners×3、gy-004:sgl-project-sglang×2、gy-004:sfs-local-system×2、gy-004:monitoring 等11方） |
| `b46afb97-6954-11f1-af0f-fa16412f71d0` | gy-005×21、gy-003×4、gy-004×1 | absolute×22、subpath×4 | 74.2TiB / 用 56.4TiB | ok（76%） | gy003/004/005 **三集群**共用 benchmarks 大盘（runner /root/.cache 41.9TiB）+ gy005 squid subpath。subpath 4 目录：持久卷 gy-005:squid/cache-squid-cache-0（200Gi）、gy-005:squid/registry-cache-squid-cache-0（400Gi）、gy-005:squid/cache-squid-cache-1（200Gi）、gy-005:squid/registry-cache-squid-cache-1（400Gi）；export `/ascend-ci-share-nv-action-vllm-benchmarks` ×20 PV（gy-005:vllm-project×2、gy-005:ascend-gha-runners×2、gy-003:monitoring、gy-003:model-download、gy-003:vllm-project 等18方）；export `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` ×1 PV（gy-003:vllm-ascend-ci-dev-vllm-ascend）；export `/` ×1 PV（gy-004:default） |
| `23021270-7ebf-43b2-925c-b1686da4868a` | gy-005×16、gy-003×6 | absolute×22 | ≈33TiB(爆发) / 用 ≈32.9TiB | ok（100% 爆满!） | 旧 benchmarks 镜像盘（疑似 24dd…/b46… 的副本，可评估退役 32.6TiB）+ gy005 pytorch ccache。export `/ascend-ci-share-nv-action-vllm-benchmarks` ×18 PV（gy-003:ascend-gha-runners×2、gy-005:ascend-gha-runners×2、gy-003:monitoring、gy-003:vllm-project、gy-003:nv-action 等16方）；export `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` ×2 PV（gy-005:monitoring、gy-005:vllm-ascend-ci-dev-vllm-ascend）；export `/ascend-ci-share-pkking-pytorch` ×2 PV（gy-005:monitoring、gy-005:ascend-pytorch） |
| `95a3d42c-f6ed-41e2-91d0-c3a113b10792` | gy-005×5 | subpath×5 | 500G* / 62G*（issue 9-17） | 未发现（IP host） | gy005 大共享盘：nginx + git-cdn + smart-git-proxy —— **#1706 后 450G vs 500G 最紧张的一块**。subpath 5 目录：runner 工作卷×2（64Gi 占位，随 job 建删）；持久卷 gy-005:git-cdn/git-cdn-workdir（200Gi）、gy-005:nginx-pypi-cache/pypi-cache-data-volume（1Ti）、gy-005:smart-git-proxy/smart-git-proxy-mirrors（500Gi） |
| `45eb5e4c-ea7c-4ae2-a0c1-f84867ce74e1` | gy-006×26 | subpath×26 | 500G* / 421G*（issue 9-17） | 未发现（IP host） | gy006 大共享盘（issue 421G 现场）：harbor/squid/grafana/argo/共享缓存/nginx 混住。subpath 26 目录：持久卷 gy-006:argo/68c3d707ca41441096025017b415b482-ci（8Gi）、gy-006:argo/ascend-ascendnpu-ir（8Gi）、gy-006:argo/ascend-archive-ascendnpu-ir（1Gi）、gy-006:argo/testorg-testrepo-test15（1Gi）、gy-006:argo/test（1Gi）、gy-006:ascend-gha-runners/ascend-gha-runners-gy006（1.2Ti）、gy-006:ascend-gha-runners/ascend-gha-runners-vllm-ascend-gy006（1.2Ti）、gy-006:ascend-gha-runners/sglang-npu-sglang-v3（600Gi）、gy-006:git-cdn/git-cdn-workdir（200Gi）、gy-006:harbor/harbor-jobservice（1Gi）、gy-006:harbor/data-harbor-trivy-0（5Gi）、gy-006:harbor/harbor-registry（1000Gi）、gy-006:harbor/data-harbor-trivy-1（5Gi）、gy-006:mindstudio/pvc-mindstudio（50Gi）、gy-006:monitoring/grafana-storage（20Gi）、gy-006:nginx-pypi-cache/pypi-cache-data-volume（1Ti）、gy-006:nv-action/nv-action-vllm-benchmarks-gy006（1.2Ti）、gy-006:ragsdk/testorg-testrepo-test15（1Gi）、gy-006:sfs-local-system/ascend-gha-runners-vllm-ascend-gy006（1.2Ti）、gy-006:smart-git-proxy/smart-git-proxy-mirrors（500Gi）、gy-006:squid/cache-squid-cache-1（50Gi）、gy-006:squid/cache-squid-cache-0（50Gi）、gy-006:squid/registry-cache-squid-cache-1（200Gi）、gy-006:squid/registry-cache-squid-cache-0（200Gi）、gy-006:vllm-ascend-vllm-ascend-kimi-k3/gy006-vllm-ascend（1.2Ti）、gy-006:vllm-project/vllm-project-vllm-ascend-gy006（1.2Ti） |
| `c95e5768-8698-11f1-a5a7-fa16445a2e80` | gy-006×2 | absolute×2 | 1.2TiB / 用 25GiB | ok（2%） | gy006 双 claim。export `/` ×2 PV（gy-006:buildkitd×2）；⚠ 孤儿 PV ×2：gy-006:buildkitd/buildkitd-amd64-cache（Released）、gy-006:buildkitd/buildkitd-arm64-cache（Released） |
| `d561f410-2692-4a18-9c3f-bbfcd3b6012f` | infra-gy-001×24 | subpath×15、absolute×9 | 3.6T* / 2.0T*（issue 9-17） | 集群无上报（guiyang-001） | infra-gy 大共享盘：nginx + cosdt/argo/op-plugin CI + runner 缓存。subpath 15 目录：runner 工作卷×7（64Gi 占位，随 job 建删）；持久卷 infra-gy-001:argo/testorg-testrepo-test15（1Gi）、infra-gy-001:argo/ascend-ascendnpu-ir（1Gi）、infra-gy-001:ascend-data-sync/testorg-testrepo-test15（10Gi）、infra-gy-001:git-cdn/git-cdn-workdir（200Gi）、infra-gy-001:nginx-pypi-cache/pypi-cache-data-volume（1Ti）、infra-gy-001:op-plugin/ascend-op-plugin（100Gi）、infra-gy-001:op-plugin/pvc-ascend-pytorch-for-lingqu（100Gi）、infra-gy-001:ragsdk/testorg-testrepo-test15（1Gi）；export `/ascend-ci-share` ×9 PV（infra-gy-001:devin-dc-huang、infra-gy-001:opensourceways、infra-gy-001:vllm-project、infra-gy-001:vllm-ascend-vllm-ascend-recipes、infra-gy-001:cosdt-ci-test 等9方） |
| `2c26b4ff-7912-11f1-9ab0-fa16446e05c1` | infra-gy-001×16 | absolute×16 | ? / ? | 集群无上报（guiyang-001） | infra-gy runner `/root/.cache` 共享盘（16 个 ns claim）。export `/mindspeed-llm` ×2 PV（infra-gy-001:mindspeed-bridge、infra-gy-001:mindspeed-llm）；export `/` ×1 PV（infra-gy-001:ascend-data-sync）；export `/drivingSDK` ×1 PV（infra-gy-001:drivingsdk）；export `/FSDPTurbo` ×1 PV（infra-gy-001:fsdpturbo）；export `/indexsdk` ×1 PV（infra-gy-001:indexsdk）；export `/MegatronAdaptor` ×1 PV（infra-gy-001:megatronadaptor）；export `/mindspeed` ×1 PV（infra-gy-001:mindspeed）；export `/mindspeed-mm` ×1 PV（infra-gy-001:mindspeed-mm）；export `/mindspeed-ops` ×1 PV（infra-gy-001:mindspeed-ops）；export `/mindstudio` ×1 PV（infra-gy-001:mindstudio）；export `/multimodalsdk` ×1 PV（infra-gy-001:multimodalsdk）；export `/ragsdk` ×1 PV（infra-gy-001:ragsdk）；export `/recsdk` ×1 PV（infra-gy-001:recsdk）；export `/slime-ascend` ×1 PV（infra-gy-001:slime-ascend）；export `/mindx` ×1 PV（infra-gy-001:visionsdk） |
| `488cfc84-5378-11f1-8401-fa16412f71d0` | infra-gy-001×8 | subpath×8 | ? / ? | 集群无上报（guiyang-001） | infra-gy harbor 专用盘：registry（2Ti 占位）+ trivy/jobservice + squid。subpath 8 目录：持久卷 infra-gy-001:harbor/harbor-registry（2Ti）、infra-gy-001:harbor/data-harbor-trivy-1（5Gi）、infra-gy-001:harbor/data-harbor-trivy-0（5Gi）、infra-gy-001:harbor/harbor-jobservice（1Gi）、infra-gy-001:squid/registry-cache-squid-cache-0（200Gi）、infra-gy-001:squid/cache-squid-cache-1（200Gi）、infra-gy-001:squid/cache-squid-cache-0（200Gi）、infra-gy-001:squid/registry-cache-squid-cache-1（200Gi） |
| `cf5c6fef-ab67-11f1-b6fa-fa16412f71d0` | infra-gy-001×4 | absolute×4 | ? / ? | 集群无上报（guiyang-001） | infra-gy 小型共享（3-4 claim）。export `/op-plugin-0731` ×1 PV（infra-gy-001:argo）；export `/perform-compare` ×1 PV（infra-gy-001:argo）；export `/` ×1 PV（infra-gy-001:sfs-local-mount）；export `/share-pv-test` ×1 PV（infra-gy-001:sfs-test） |
| `6a6b9cc9-9c4a-11f1-b6fa-fa16412f71d0` | infra-gy-001×3 | absolute×3 | ? / ? | 集群无上报（guiyang-001） | infra-gy 小型共享。export `/cann` ×1 PV（infra-gy-001:cann）；export `/memcache` ×1 PV（infra-gy-001:memcache）；export `/memfabric-hybrid` ×1 PV（infra-gy-001:memfabric-hybrid） |
| `d5fa7449-ab88-11f1-8ea6-fa16446e05c1` | infra-gy-001×2 | absolute×2 | ? / ? | 挂载失败（-1（guiyang-002 侧探测）） | infra-gy 双 claim。export `/` ×2 PV（infra-gy-001:argo、infra-gy-001:shared-sfs） |
| `ba20b346-a7bd-48aa-9a41-3dbf0c7c03a6` | aiframework×21 | subpath×21 | ? / ? | 未发现（IP host） | aiframework 大共享盘：nginx + 18 个 runner 工作卷 + gha-runners 缓存。subpath 21 目录：runner 工作卷×18（64Gi 占位，随 job 建删）；持久卷 aiframework:ascend-gha-runners/ascend-gha-runners-pytorch（200Gi）、aiframework:git-cdn/git-cdn-workdir（200Gi）、aiframework:nginx-pypi-cache/pypi-cache-data-volume（1Ti） |
| `c461cb6e-61fd-4655-9e27-49a24e459a34` | aiframework×16 | absolute×16 | 30.4TiB / 用 27.9TiB | ok（92%⚠） | aiframework runner `/root/.cache` 共享盘。export `/` ×16 PV（aiframework:areal-project-areal×2、aiframework:verl-project-liqo×2、aiframework:monitoring、aiframework:model-download、aiframework:vllm-ascend-800i-aiframe 等14方） |
| `9ffa8aa5-9730-4f7a-ab13-d45a47ea2b78` | aiframework×4 | absolute×4 | 2.4TiB / 用 74GiB | ok（3%） | aiframework 小型共享。export `/ascend-ci-share-pkking-pytorch` ×3 PV（aiframework:monitoring、aiframework:ascend、aiframework:vllm-project-vllm-ascend）；export `/ascend-ci-share-areal` ×1 PV（aiframework:monitoring） |
| `a8317f79-8762-4a9c-a18c-ebae7ce2ad0e` | mind-third-ci×28 | subpath×21、absolute×7 | 2.4TiB / 用 666GiB | ok（27%） | mind-third-ci 大共享盘：nginx 等 21 subpath + 7 个 runner 缓存 absolute 同盘。subpath 21 目录：runner 工作卷×19（64Gi 占位，随 job 建删）；持久卷 mind-third-ci:git-cdn/git-cdn-workdir（200Gi）、mind-third-ci:nginx-pypi-cache/pypi-cache-data-volume（1Ti）；export `/ascend-ci-share` ×4 PV（mind-third-ci:monitoring、mind-third-ci:verl-project、mind-third-ci:ascend-gha-runners、mind-third-ci:verl-project-liqo）；export `/ascend-ci-share-vllm` ×2 PV（mind-third-ci:monitoring、mind-third-ci:vllm-project-vllm-ascend）；export `/` ×1 PV（mind-third-ci:default） |
| `cc8060b8-acf6-11f1-b392-fa163eca185d` | mind-third-ci×14 | absolute×14 | 43.8TiB / 用 25.8TiB | ok（59%） | mind-third-ci runner `/root/.cache` 共享盘。export `/` ×14 PV（mind-third-ci:areal-project-areal×2、mind-third-ci:model-download、mind-third-ci:vllm-ascend-800i-mind、mind-third-ci:alibaba-roll-liqo、mind-third-ci:ascend-sglang 等13方） |
| `19fa9411-b0d5-40b6-b2db-f32b178f8cd3` | mind-third-ci×3 | absolute×3 | ? / ? | 挂载失败（-1） | mind-third-ci 共享（3×10Ti 占位）。export `/` ×3 PV（mind-third-ci:monitoring、mind-third-ci:model-download、mind-third-ci:verl-project-liqo） |
| `179.60.12.2` | sh-002×5 | static×5 | ? / ? | — | sh-002 静态 NFS：5 个 CI share-pvc 各 1.2Ti 占位。export `/home/share/ascend-ci-share-pytorch` ×1 PV（sh-002:ascend-pytorch）；export `/home/share/ascend-ci-share-triton` ×1 PV（sh-002:triton-ascend）；export `/home/share/ascend-ci-share-sgl-kernel-npu` ×1 PV（sh-002:sgl-kernel-npu）；export `/home/share/ascend-ci-share-sglang` ×1 PV（sh-002:sgl-project）；export `/home/share/ascend-ci-share-vllm-ascend-test` ×1 PV（sh-002:ascend-gha-runners） |

k8s 对象之外、kubectl 不可见的共享盘（来源：彼文 du 盘点 / issue）：

| 物理盘 | 关联集群 | 大小/实测 | 盘下分配与用途 |
|---|---|---|---|
| NFS `suzblue.server:/share` | sh-001（hostPath 直挂） | 317T，用 41T | 整盘与人共用；CI 侧 `/mnt/share/vllm-ascend`＝runner `/root/.cache`（modelscope 11.9T）；**无清理器** |
| NFS `suzblue.server:/weight` | sh-001（hostPath） | 358T，用 82T | 整盘模型权重库（历史遗留，当前 pod-template 未挂） |
| SFS Turbo（ID 未知） | wlcb-001 | 1.2T，用 4.4G | nginx `-new` 缓存卷等；本地无 kubeconfig 未采集 |


### 监控覆盖情况（主监控：中心 Prometheus `http://113.44.182.82:9090`，@2026-09-18）

链路：`monitoring/base/cronjob-sfs-turbo-disk.yaml`（每 10min，各集群）→ 列举 PV 按 share-id 去重 → chroot 挂 NFS + `df` → pushgateway → 中心；告警：`SharedDiskHighUsage`（>90% 5m critical）、`SharedDiskMountFailed`（mount_ok=0）、指标新鲜度 dead-man（>20min）。见 `config-for-infra-cn4/prometheus-rules.yaml`。

- **可观测（18/27 块，含水位+告警）**：上表状态 `ok`。当前已过 90% 告警线的：**`23021270` 100%（旧镜像盘实际写爆，仅剩~0.3TiB）**、`37cbefa6` 96%、`c461cb6e` 92%、`9c241417` 91%；76~80% 的 `24dd126e`/`b46afb97`/`1b51fb58` 次高。
- **监控额外看到的非共享表盘**：`8258ca0d`（cn12 sfs-local-mount 探测挂载）**99%**、`a3d80a1b`（gy003 coder 盘）86%、`87d772ee`/`c5803d39`（hk 独立盘）~0%。
- **真空区（水位不可见、不会告警）**：
  1. **IP host 漏发现 ×3**：cronjob 发现逻辑只认 `*.sfsturbo.internal` host，而这 3 块盘的 PV export location 写的是 IP——**`45eb5e4c`（gy006，issue 421G 现场）、`95a3d42c`（gy005，#1706 450G 风险盘）、`ba20b346`（aiframework）**。gy006 盘写爆都不会触发盘告警，与 issue 验收项 2「使用率告警接入」直接冲突。
  2. **infra-gy-001（监控标签 guiyang-001）无任何上报**：cronjob/agent 未部署或未跑 → `d561f410`（3.6T/用 2.0T！）、`2c26b4ff`、`488cfc84`（harbor）、`cf5c6fef`、`6a6b9cc9` 全盲。`config-for-wlcb-001` 有配置但中心无 wlcb 序列 → wlcb 盘同样真空。
  3. **拨测挂载失败 ×2**：`19fa9411`（mind-third-ci）、`d5fa7449`（infra-gy，guiyang-002/ipv6 集群侧探的）——有挂载失败告警但水位 -1 不可知（网络/ACL 未放通）。
  4. **非 SFS 体系**：sh-002 静态 NFS `179.60.12.2`、sh-001 `suzblue:/share`(317T)/`:/weight`(358T)、suzeau/hk-ci——无 agent 或驱动不在 cronjob 范围。
  5. **归因真空**：kubelet `volume_stats` 全链路未采集（KSM 只有 requests 声明值）；nginx 各缓存 zone 实际大小、harbor registry 实际用量均无指标（squid 有 exporter 但仅 cn12/guiyang-001/002 job）→「盘用了多少」能看到，「谁用的」只能靠 Part II du 一次性任务。
- **顺手可修的监控 bug**：① `shared_disk_available_bytes` 实为 `df -P` 的 **1K 块数**，指标名/换算是错的（差 1024×）；② 发现过滤器建议改为从 `volume-id`/`sfsturbo-share-id` 属性取 UUID（不依赖 export host 形态）。

## 3. nginx max_size 收紧生效核对（live ConfigMap，2026-09-18）

| 集群 | 挂载的 CM | Σ max_size | 明细 | 状态 |
|---|---|---|---|---|
| hk-001 | `pypi-cache-conf` | 400G | pypi150+deb100+rustup60+go60+yum30 | 收紧后 ✓ |
| cn12-001 | `pypi-cache-conf-7c5m265bfh` | 1480G | 500+500+200+200+200+80 (v2) | ⚠ 未收紧（#1695 未覆盖 v2 目录） |
| gy-003 | `pypi-cache-conf` | 400G | 同上 | 收紧后 ✓ |
| gy-004 | `pypi-cache-conf` | 400G | 同上 | 收紧后 ✓ |
| gy-005 | `pypi-cache-conf` | 400G | 同上 | 收紧后 ✓ |
| gy-006 | `pypi-cache-conf-dk2f7975gt` | 50G | pypi20+deb10+go6+crates5+rustup6+yum3 | 收紧后 ✓（旧 1480G CM 残留） |
| infra-gy-001 | `pypi-cache-conf` | 400G | pypi150+deb100+rustup60+go60+yum30 | 收紧后 ✓ |
| aiframework | `pypi-cache-conf` | 400G | 同上 | 收紧后 ✓ |
| mind-third-ci | `pypi-cache-conf` | 400G | 同上 | 收紧后 ✓ |
| sh-002 | `pypi-cache-conf` | 1480G | 500+500+200+200+80 | ⚠ 未收紧，缓存 PVC 还 Pending |
| wlcb-001 | — | 预期 400G | 无 kubeconfig | ❌ 待有权同学核对 |

**风险与建议（含 PR #1706）**：
- [ ] **#1706 会把 -new 总和抬到 450G**（新增 crates 50G），且把 #1695 注释从"80% 封顶(400G)"改成"按 500G 封顶"。对 **gy-005（盘 `95a3d42c` 共 500G，同盘还有 git-cdn/smart-git-proxy/runner 卷，盘已用 62G）**：450G 缓存填满即整爆、零余量 ENOSPC。建议：crates 收下压总量回 ≤400G，或给 gy-005 加 overlay 单独收紧。其余 -new 集群盘 ≥1.2T，450G 无压力。
- [ ] cn12-001 v2 目录同步收紧（其盘 2.4T/已用 56%，nginx 独占部分安全，但口径要与 #1695 一致）。
- [ ] sh-002：live 仍 1480G 且 PVC Pending；gy-006：删除孤儿旧 CM。
- [ ] gy-006 `45eb5e4c` 421G 治理（harbor/squid/argo/个人目录等）见彼文 §7 与 issue 验收项 3。

## 4. 各集群 PVC 归属清单

共享盘成员归 §2 总表；此处逐集群列：**共享盘上的持久卷**（`-work` 工作卷只计数）+ **独立盘 PVC 逐行**。

### 4.1 hk-001 — ascend-hk-001-cluster

kubeconfig `~/.kube/configs/ascend-hk-001-cluster-kubeconfig.yaml` ｜ `ap-southeast-1` ｜ nginx 布局 `-new` ｜ PVC **93** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `24dd126e…` | 24 | 0 | ascend/vllm-project-hk001（1.2Ti）、ascend-gha-runners/ascend-gha-runners-hk001（1.2Ti）、ascend-gha-runners/pvc-hk001-vllm（1.2Ti）、ascend-gha-runners-hk-001/vllm-ascend-hk-001（1.2Ti）、codemayq-transformers/codemayq-transformers-a2-hk-001（1.2Ti）、cosdt/vllm-project-hk001（1.2Ti）、fla-org-flash-linear-attention/fla-org-flash-linear-attention-a2-hk-001（1.2Ti）、ganding-rlinf/ganding-rlinf-a2-hk-001（1.2Ti）、gdzhu01/vllm-project-hk001（1.2Ti）、goalina-transformers/goalina-transformers-a2-hk-001（1.2Ti）、linkedin/vllm-project-hk001（1.2Ti）、monitoring/pvc-cache-cleanup-hk-cidev（1.2Ti）、monitoring/pvc-cache-cleanup-hk-nvbench（1.2Ti）、monitoring/pvc-cache-cleanup-hk-share（1.2Ti）、nv-action/vllm-project-hk001（1.2Ti）、sfs-local-system/ascend-gha-runners-hk001（1.2Ti）、triton-ascend/ascend-triton-ascend-hk001（1.2Ti）、vllm-ascend-ci-dev-vllm-ascend/vllm-ascend-ci-dev-vllm-ascend-hk001（1.2Ti）、vllm-ascend-main2main-automator/vllm-project-hk001（1.2Ti）、vllm-ascend-vllm-ascend-kimi-k3/vllm-project-hk001（1.2Ti）、vllm-project/vllm-project-hk001（1.2Ti）、vllm-project-vllm-ascend/vllm-ascend-sz-lab（1.2Ti）、xuedinge233/vllm-project-hk001（1.2Ti）、xuedinge233-triton-ascend/triton-ascend-hk001（1.2Ti） |
| `d5b643e2…` | 58 | 40 | ascend-docs/hk001-v1（1.2Ti）、ascend-gha-runners/hk001-v1（1.2Ti）、git-cdn/git-cdn-workdir（200Gi）、hiyouga/hk001-v1（1.2Ti）、modelscope/hk001-v1（1.2Ti）、monitoring/pvc-cache-cleanup-hk-d5share（1.2Ti）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、nginx-test/test（1.2Ti）、pt-ecosystem-flash-linear-attention-dev/hk001-v1（1.2Ti）、pytorch-fdn/hk001-v1（1.2Ti）、sfs-system/cleanup-sfs-turbo-for-ascend-verl-ci（6Ti）、smart-git-proxy/smart-git-proxy-mirrors（500Gi）、squid/registry-cache-pvc（400Gi）、squid/squid-cache-pvc（200Gi）、usernamefull-transformers-ci/hk001-v1（1.2Ti）、verl-project-uni-agent/verl-uni-agent-hk001（1.2Ti）、verl-project-verl-speco/verl-verl-speco-hk001（1.2Ti）、volcengine/hk001-v1（1.2Ti） |
| `9c241417…` | 8 | 0 | ascend/ascend-sglang-hk001（1.2Ti）、ascend-gha-runners/sgl-project-sglang-hk001（1.2Ti）、ascend-gha-runners/pvc-hk001-sglang（1.2Ti）、monitoring/pvc-cache-cleanup-hk-sglang（1.2Ti）、sfs-local-system/ascend-ci-share-pkking-sglang（1.2Ti）、sgl-kernel-npu/sgl-project-sglang-hk001（1.2Ti）、sgl-project/sgl-project-sglang-hk001（1.2Ti）、sgl-project-sglang-omni/sgl-project-sglang-hk001（1.2Ti） |

**独立盘 / 其他 PVC（4 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | vault | data-vault-0 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 2 | monitoring | pvc-prometheus-server-0 | Bound | 200Gi | csi-disk-topology | disk·disk |
| 3 | buildkitd | buildkitd-cache | Released | 1.2Ti | csi-sfsturbo | sfsturbo·87d772ee…（absolute） |
| 4 | sfs-local-mount | pvc-sfs-turbo-local-mount.c5803d39-6bf4-46dd-b6ad-983e0631cb8e | Bound | 1.2Ti | csi-sfsturbo | sfsturbo·c5803d39…（absolute） |

### 4.2 cn12-001 — ascend-cn12-001-cluster

kubeconfig `~/.kube/configs/ascend-cn12-001-cluster-kubeconfig.yaml` ｜ `cn-north-12` ｜ nginx 布局 `v2` ｜ PVC **271** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `37cbefa6…` | 41 | 0 | alibaba-roll/alibaba-roll-cn12-001（1.2Ti）、alibaba-roll-liqo/alibaba-roll-liqo-cn12-001-v2（1.2Ti）、areal-project-areal/areal-project-areal-cn12-001-v2（1.2Ti）、areal-project-areal/areal-project-areal-shared-v3（1.2Ti）、ascend/ascend-sglang-cn12-001-v2（1.2Ti）、ascend/ascend-sglang-cn12-001（1.2Ti）、ascend-docs/ascend-docs-cn12-001（1.2Ti）、ascend-gha-runners/sglang-public-v2（1.2Ti）、ascend-gha-runners/nv-action-vllm-benchmarks-v2（1.2Ti）、ascend-gha-runners/omni-hb003（1.2Ti）、ascend-gha-runners-gy004/sglang-guiyang004（1.2Ti）、ascend-gha-runners-gy005/nv-action-vllm-benchmarks-v2（1.2Ti）、ascend-gha-runners-gy005/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-gha-runners-gy006/ascend-gha-runners-vllm-ascend-gy006（1.2Ti）、ascend-pytorch/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-sglang/ascend-sglang-cn12-001-v2（1.2Ti）、liqo-test/liqo-test-share（14.4Ti）、monitoring/pvc-cache-cleanup-cn12-share（1.2Ti）、nv-action/gy005-az5-vllm-ascend-v2（1.2Ti）、sfs-local-system/ascend-ci-share（1.2Ti）、sfs-local-system/nv-action-vllm-benchmarks-v2（1.2Ti）、sgl-kernel-npu/sglang-cn12-001（1.2Ti）、sgl-project-sgl-kernel-npu/sgl-project-sgl-kernel-npu-liqo-v2（1.2Ti）、sgl-project-sglang/sglang-guiyang004（1.2Ti）、sgl-project-sglang/sglang-shared-v2（1.2Ti）、tecjesh-triton-ascend/triton-ascend-cn12-001-pvc（1.2Ti）、tile-ai-tilelang-mlir-ascend/tile-ai-tilelang-ascend-gy005（1.2Ti）、tile-ai-tilelang-mlir-ascend-liqo/tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2（1.2Ti）、triton-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、triton-ascend/ascend-triton-ascend-gy005（1.2Ti）、triton-ascend-liqo/triton-ascend-liqo-cn12-001-v2（1.2Ti）、verl-project-liqo/verl-project-liqo-cn12-001-v2（1.2Ti）、verl-project-liqo/verl-project-liqo-cn12-001（1.2Ti）、vllm-ascend/nv-action-vllm-benchmarks-v2（1.2Ti）、vllm-ascend-vllm-ascend-recipes/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project/test（1Gi）、vllm-project/vllm-omni-cn12-001（1.2Ti）、vllm-project/nv-action-vllm-benchmarks-v2（1.2Ti）、vllm-project-vllm-ascend/nv-action-vllm-benchmarks-v2（1.2Ti）、vllm-project-vllm-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project-vllm-omni/vllm-project-vllm-omni-cn12-001-v2（1.2Ti） |
| `665a3415…` | 220 | 212 | buildkitd/test（10Gi）、git-cdn/git-cdn-workdir（200Gi）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、squid/cache-squid-cache-1（200Gi）、squid/registry-cache-squid-cache-0（400Gi）、squid/cache-squid-cache-0（200Gi）、squid/registry-cache-squid-cache-1（400Gi）、usernamefull/usernamefull-roll-cn12-001（1.2Ti） |

**独立盘 / 其他 PVC（12 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | buildkitd | pvc-buildkitd-cache01 | Released | 300Gi | csi-disk | disk·disk |
| 2 | buildkitd | pvc-buildkitd-cache02 | Released | 300Gi | csi-disk | disk·disk |
| 3 | vault | data-vault-0 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 4 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 5 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 6 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 7 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-3 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 8 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 9 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 10 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 11 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-3 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 12 | sfs-local-mount | pvc-sfs-turbo-local-mount.8258ca0d-8dce-4a35-8802-79d10e0f8f9f | Bound | 1.2Ti | csi-sfsturbo | sfsturbo·8258ca0d…（absolute） |

### 4.3 gy-003 — openmerlin-guiyang-003-cluster

kubeconfig `~/.kube/configs/openmerlin-guiyang-003-cluster-kubeconfig.yaml` ｜ `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC **52** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `39a33a00…` | 18 | 0 | arc-systems/ascend-ci-share（100Gi）、ascend/custom-index（50Mi）、ascend/ascend-ci-share-ascend-ascend-ci（100Gi）、ascend-gha-runners/custom-index（50Mi）、ascend-gha-runners/ascend-ci-share（100Gi）、cllouud/custom-index（50Mi）、cllouud/ascend-ci-share（100Gi）、cllouud/ascend-ci-hook-index（50Mi）、cosdt/ascend-ci-share-cosdt（100Gi）、cosdt/cosdt-store（100Mi）、cosdt/custom-index（50Mi）、listener-pod-persistence/prometheus-pvc（200Gi）、monitoring/pvc-cache-cleanup-gy003-39a（100Gi）、nv-action/ascend-ci-hook-index（50Mi）、nv-action/custom-index（50Mi）、nv-action/ascend-ci-share-nv-action-vllm-benchmarks（500Gi）、pytorch-fdn/ascendci-pytorch-fdn-oota（100Gi）、pytorch-fdn/custom-index（50Mi） |
| `23021270…` | 6 | 0 | ascend-gha-runners/nv-action-vllm-benchmarks-v2（1.2Ti）、ascend-gha-runners/nv-action-vllm-benchmarks-v3（1.2Ti）、cllouud/nv-action-vllm-benchmarks-v2（1.2Ti）、monitoring/pvc-cache-cleanup-gy003-230nv（1.2Ti）、nv-action/nv-action-vllm-benchmarks-v2（1.2Ti）、vllm-project/nv-action-vllm-benchmarks-v2（1.2Ti） |
| `b46afb97…` | 4 | 0 | model-download/model-download-cache（1.2Ti）、monitoring/pvc-cache-cleanup-gy003-b46nv（1.2Ti）、vllm-ascend-ci-dev-vllm-ascend/vllm-ascend-ci-dev-vllm-ascend-gy003（1.2Ti）、vllm-project/gy003-az5-vllm-ascend（1.2Ti） |
| `0ca03ada…` | 12 | 8 | git-cdn/git-cdn-workdir（200Gi）、nginx-pypi-cache/sfs-turbo-pypi-cache-data-volume（1.2Ti）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、sfs-system/cleanup-sfs-turbo-ascend-ci-02（1.2Ti） |

**独立盘 / 其他 PVC（13 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | coder | coder-00eb6ddf-5562-4d7c-8553-101763fbd4a6-home | Bound | 1000Gi | csi-disk | disk·disk |
| 2 | coder | coder-1de3c53e-25bd-4657-a9de-7aa7bf158bc9-home | Bound | 100Gi | csi-disk | disk·disk |
| 3 | coder | coder-324724f5-0445-42ee-b11b-3db3ab7bf650-home | Bound | 100Gi | csi-disk | disk·disk |
| 4 | coder | coder-5c8888bf-8728-4413-815b-4fd17ee5f147-home | Bound | 100Gi | csi-disk | disk·disk |
| 5 | coder | coder-8418dc3c-d6da-4810-8e39-53833602e9be-home | Bound | 100Gi | csi-disk | disk·disk |
| 6 | coder | coder-95f186a6-0474-40cb-a29d-948b4365d02e-home | Bound | 100Gi | csi-disk | disk·disk |
| 7 | coder | coder-9c83e2c0-5daf-4c24-a530-c63dbb974c8e-home | Bound | 100Gi | csi-disk | disk·disk |
| 8 | coder | coder-c64e61cc-5e5e-47c3-bbae-00781f9df657-home | Bound | 100Gi | csi-disk | disk·disk |
| 9 | coder | coder-cece37ec-2241-4ba3-840a-0e4a608b8b50-home | Bound | 200Gi | csi-disk | disk·disk |
| 10 | npu-exporter | prometheus | Bound | 10Gi | csi-disk | disk·disk |
| 11 | monitoring | grafana-pvc | Bound | 105Gi | csi-disk-topology | disk·disk |
| 12 | cllouud | test | Bound | 1Gi | csi-sfs | nas·05682530…（absolute） |
| 13 | coder | sfs-turbo-coder | Bound | 2.4Ti | csi-sfsturbo | sfsturbo·a3d80a1b…（absolute） |

### 4.4 gy-004 — openmerlin-guiyang-004-cluster

kubeconfig `~/.kube/configs/openmerlin-guiyang-004-cluster-kubeconfig.yaml` ｜ `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC **79** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `1b51fb58…` | 17 | 0 | ascend/sglang-npu-sglang-v3（1.2Ti）、ascend/sgl-project-sglang-v3（1.2Ti）、ascend/sglang-guiyang004（1.2Ti）、ascend-gha-runners/sglang-npu-sglang-v3（1.2Ti）、ascend-gha-runners/sgl-project-sglang-v2（1.2Ti）、ascend-gha-runners/sglang-guiyang004（1.2Ti）、ascend-gha-runners-cn12-001/sglang-guiyang004（1.2Ti）、ascend-sglang/ascend-sglang-cn12-001-v2（1.2Ti）、monitoring/pvc-cache-cleanup-gy004-share（1.2Ti）、ping1jing2/sglang-guiyang004（1.2Ti）、sfs-local-system/ascend-ci-share-pkking-sglang（1.2Ti）、sfs-local-system/ascend-ci-share（1.2Ti）、sgl-kernel-npu/sglang-guiyang004（1.2Ti）、sgl-project/sglang-guiyang004（1.2Ti）、sgl-project-sgl-kernel-npu/sgl-project-sgl-kernel-npu-liqo-v2（1.2Ti）、sgl-project-sglang/sglang-shared-v2（1.2Ti）、sgl-project-sglang/sglang-guiyang004（1.2Ti） |
| `39a33a00…` | 3 | 0 | ascend/custom-index（50Mi）、ascend-gha-runners/custom-index（50Mi）、ascend-gha-runners/ascend-ci-share-ascend-gha-runners（100Gi） |
| `e745888b…` | 58 | 55 | git-cdn/git-cdn-workdir（200Gi）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、sfs-system/cleanup-sfs-turbo-ascend-ci-03（1.2Ti） |
| `b46afb97…` | 1 | 0 | default/pvc-shared（49.2Ti） |

### 4.5 gy-005 — openmerlin-guiyang-005-cluster

kubeconfig `~/.kube/configs/openmerlin-guiyang-005-cluster-kubeconfig.yaml` ｜ `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC **47** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `b46afb97…` | 21 | 0 | ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-gha-runners/test-new（1.2Ti）、ascend-gha-runners/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-gha-runners-cn12-001/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-pytorch/gy005-az5-vllm-ascend-v2（1.2Ti）、gdzhu01/gy005-az5-vllm-ascend-v2（1.2Ti）、nv-action/gy005-az5-vllm-ascend-v2（1.2Ti）、sfs-local-system/nv-action-vllm-benchmarks-v2（1.2Ti）、squid/cache-squid-cache-0（200Gi）、squid/registry-cache-squid-cache-0（400Gi）、squid/cache-squid-cache-1（200Gi）、squid/registry-cache-squid-cache-1（400Gi）、tile-ai/gy005-az5-vllm-ascend-v2（1.2Ti）、tile-ai-tilelang-mlir-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、triton-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-ascend-ci-dev-vllm-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-ascend-vllm-ascend-kimi-k3/gy005-az5-vllm-ascend（1.2Ti）、vllm-project/gy005-az5-vllm-ascend（1.2Ti）、vllm-project/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project-vllm-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、xuedinge233-triton-ascend/gy005-az5-vllm-ascend-v2（1.2Ti） |
| `23021270…` | 16 | 0 | ascend/ascend-ray-ascend-gy005（1.2Ti）、ascend-gha-runners/sync-guiyang-005（1.2Ti）、ascend-gha-runners/nv-action-vllm-benchmarks-v2（1.2Ti）、ascend-gha-runners-cn12-001/nv-action-vllm-benchmarks-v2（1.2Ti）、ascend-pytorch/ascend-pytorch-gy005（1.2Ti）、gdzhu01/nv-action-vllm-benchmarks-v2（1.2Ti）、monitoring/pvc-cache-cleanup-gy005-cidev（1.2Ti）、monitoring/pvc-cache-cleanup-gy005-pytorch（1.2Ti）、nv-action/nv-action-vllm-benchmarks-v2（1.2Ti）、tile-ai/tile-ai-tilelang-ascend-gy005（1.2Ti）、tile-ai-tilelang-mlir-ascend/tile-ai-tilelang-ascend-gy005（1.2Ti）、triton-ascend/ascend-triton-ascend-gy005（1.2Ti）、vllm-ascend-ci-dev-vllm-ascend/vllm-ascend-ci-dev-vllm-ascend-gy005（1.2Ti）、vllm-project/nv-action-vllm-benchmarks-v2（1.2Ti）、vllm-project-vllm-ascend/nv-action-vllm-benchmarks-v2（1.2Ti）、xuedinge233-triton-ascend/ascend-triton-ascend-gy005（1.2Ti） |
| `39a33a00…` | 4 | 0 | ascend-gha-runners/custom-index（50Mi）、gdzhu01/custom-index（50Mi）、nv-action/custom-index（50Mi）、vllm-project/custom-index（50Mi） |
| `95a3d42c…` | 5 | 2 | git-cdn/git-cdn-workdir（200Gi）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、smart-git-proxy/smart-git-proxy-mirrors（500Gi） |

**独立盘 / 其他 PVC（15 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | ? | pv-32g-001 | Available | 32Gi | - | local·local |
| 2 | ? | pv-32g-002 | Available | 32Gi | - | local·local |
| 3 | ? | pv-32g-003 | Available | 32Gi | - | local·local |
| 4 | ? | pv-32g-004 | Available | 32Gi | - | local·local |
| 5 | ? | pv-32g-005 | Available | 32Gi | - | local·local |
| 6 | ? | pv-32g-006 | Available | 32Gi | - | local·local |
| 7 | ? | pv-32g-007 | Available | 32Gi | - | local·local |
| 8 | ? | pv-32g-008 | Available | 32Gi | - | local·local |
| 9 | ? | pv-64g-001 | Available | 64Gi | - | local·local |
| 10 | ? | pv-64g-002 | Available | 64Gi | - | local·local |
| 11 | ? | pv-64g-003 | Available | 64Gi | - | local·local |
| 12 | ? | pv-64g-004 | Available | 64Gi | - | local·local |
| 13 | ? | pv-retain-1 | Available | 32Gi | - | local·local |
| 14 | ? | pv-retain-2 | Available | 32Gi | - | local·local |
| 15 | monitoring | pvc-prometheus-server-0 | Bound | 400Gi | csi-disk-topology | disk·disk |

### 4.6 gy-006 — openmerlin-guiyang-006-cluster

kubeconfig `~/.kube/configs/openmerlin-guiyang-006-cluster-kubeconfig.yaml` ｜ `cn-southwest-2` ｜ nginx 布局 `-test` ｜ PVC **58** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `45eb5e4c…` | 26 | 0 | argo/68c3d707ca41441096025017b415b482-ci（8Gi）、argo/ascend-ascendnpu-ir（8Gi）、argo/ascend-archive-ascendnpu-ir（1Gi）、argo/testorg-testrepo-test15（1Gi）、argo/test（1Gi）、ascend-gha-runners/ascend-gha-runners-gy006（1.2Ti）、ascend-gha-runners/ascend-gha-runners-vllm-ascend-gy006（1.2Ti）、ascend-gha-runners/sglang-npu-sglang-v3（600Gi）、git-cdn/git-cdn-workdir（200Gi）、harbor/harbor-jobservice（1Gi）、harbor/data-harbor-trivy-0（5Gi）、harbor/harbor-registry（1000Gi）、harbor/data-harbor-trivy-1（5Gi）、mindstudio/pvc-mindstudio（50Gi）、monitoring/grafana-storage（20Gi）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、nv-action/nv-action-vllm-benchmarks-gy006（1.2Ti）、ragsdk/testorg-testrepo-test15（1Gi）、sfs-local-system/ascend-gha-runners-vllm-ascend-gy006（1.2Ti）、smart-git-proxy/smart-git-proxy-mirrors（500Gi）、squid/cache-squid-cache-1（50Gi）、squid/cache-squid-cache-0（50Gi）、squid/registry-cache-squid-cache-1（200Gi）、squid/registry-cache-squid-cache-0（200Gi）、vllm-ascend-vllm-ascend-kimi-k3/gy006-vllm-ascend（1.2Ti）、vllm-project/vllm-project-vllm-ascend-gy006（1.2Ti） |
| `39a33a00…` | 7 | 0 | arc-history/pod-history-data（100Gi）、ascend-gha-runners/custom-index（50Mi）、ascend-gha-runners/ascend-ci-share（100Gi）、cllouud/ascend-ci-share（100Gi）、cllouud/custom-index（50Mi）、nv-action/custom-index（50Mi）、vllm-ascend/vllm-ascend-gy006（1.2Ti） |

**独立盘 / 其他 PVC（28 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | arc-history | pod-history-pg-data | Bound | 20Gi | csi-disk | disk·disk |
| 2 | milvus | data-my-release-etcd-0 | Bound | 10Gi | csi-disk | disk·disk |
| 3 | milvus | data-my-release-etcd-1 | Bound | 10Gi | csi-disk | disk·disk |
| 4 | milvus | data-my-release-etcd-2 | Bound | 10Gi | csi-disk | disk·disk |
| 5 | milvus | export-my-release-minio-0 | Bound | 500Gi | csi-disk | disk·disk |
| 6 | milvus | export-my-release-minio-1 | Bound | 500Gi | csi-disk | disk·disk |
| 7 | milvus | export-my-release-minio-2 | Bound | 500Gi | csi-disk | disk·disk |
| 8 | milvus | export-my-release-minio-3 | Bound | 500Gi | csi-disk | disk·disk |
| 9 | milvus | my-release-milvus | Bound | 50Gi | csi-disk | disk·disk |
| 10 | npu-exporter | prometheus | Bound | 100Gi | csi-disk | disk·disk |
| 11 | vault | data-vault-0 | Bound | 10Gi | csi-disk | disk·disk |
| 12 | vault | data-vault-0 | Released | 10Gi | csi-disk | disk·disk |
| 13 | default | agent-config-woodpecker-agent-0 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 14 | default | data-woodpecker-server-0 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 15 | karmada-system | etcd-data-ascend-ci-karmada-etcd-0 | Bound | 3Gi | csi-disk-dss | disk·disk |
| 16 | woodpecker | agent-config-woodpecker-agent-0 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 17 | woodpecker | agent-config-woodpecker-agent-1 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 18 | woodpecker | data-woodpecker-server-0 | Bound | 10Gi | csi-disk-dss | disk·disk |
| 19 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 20 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 21 | buildkitd | buildkitd-cache-buildkitd-amd64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 22 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-0 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 23 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-1 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 24 | buildkitd | buildkitd-cache-buildkitd-arm64-deployment-2 | Bound | 300Gi | csi-disk-topology | disk·disk |
| 25 | monitoring | pvc-prometheus-server-0 | Bound | 10Gi | csi-disk-topology | disk·disk |
| 26 | ? | pv-obs-guiiyang1-ascend-test | Available | 1Gi | csi-obs | obs·obs |
| 27 | ? | pv-efs-argocd-workflow | Available | 500Gi | csi-sfsturbo | sfsturbo·172.22.6…（absolute） |
| 28 | default | data-vault-0 | Pending | 10Gi | csi-disk-topology | 未绑定 |

### 4.7 infra-gy-001 — ascend-infra-guiyang-cluster-001

kubeconfig `~/.kube/configs/ascend-infra-guiyang-cluster-001-kubeconfig.yaml` ｜ `cn-southwest-2` ｜ nginx 布局 `-new` ｜ PVC **68** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `d561f410…` | 24 | 7 | argo/testorg-testrepo-test15（1Gi）、argo/ascend-ascendnpu-ir（1Gi）、ascend-data-sync/testorg-testrepo-test15（10Gi）、ascend-gha-runners-hk-001/vllm-ascend-hk-001（1.2Ti）、cosdt-ci-test/cosdt-ci-test-gy001（1.2Ti）、devin-dc-huang/devin-dc-huang-gy001（1.2Ti）、git-cdn/git-cdn-workdir（200Gi）、licy666/licy666-gy001（1.2Ti）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、op-plugin/ascend-op-plugin（100Gi）、op-plugin/pvc-ascend-pytorch-for-lingqu（100Gi）、opensourceways/opensourceways-gy001（1.2Ti）、ragsdk/testorg-testrepo-test15（1Gi）、triton-ascend/triton-ascend-gy001（1.2Ti）、verl-project-verl-omni/verl-project-verl-omni-gy001（1.2Ti）、vllm-ascend-vllm-ascend-recipes/vllm-ascend-vllm-ascend-recipes-gy001（1.2Ti）、vllm-project/vllm-project-gy001（1.2Ti） |
| `2c26b4ff…` | 16 | 0 | ascend-data-sync/ascend-data-root（6Ti）、drivingsdk/pvc-ascend-drivingsdk（6Ti）、fsdpturbo/pvc-ascend-fsdpturbo（6Ti）、indexsdk/pvc-ascend-indexsdk（4.8Ti）、megatronadaptor/pvc-ascend-megatronadaptor（6Ti）、mindspeed/pvc-ascend-mindspeed（6Ti）、mindspeed-bridge/pcv-ascend-mindspeed-bridge（6Ti）、mindspeed-llm/pvc-ascend-mindspeed-llm（6Ti）、mindspeed-mm/pvc-ascend-mindspeed-mm（6Ti）、mindspeed-ops/pvc-ascend-mindspeed-ops（6Ti）、mindstudio/pvc-mindstudio（1.2Ti）、multimodalsdk/pvc-ascend-multimodalsdk（4.8Ti）、ragsdk/pvc-ascend-ragsdk（4.8Ti）、recsdk/pvc-ascend-recsdk（4.8Ti）、slime-ascend/pvc-ascend-slime-ascend（6Ti）、visionsdk/pvc-ascend-visionsdk（6Ti） |
| `488cfc84…` | 8 | 0 | harbor/harbor-registry（2Ti）、harbor/data-harbor-trivy-1（5Gi）、harbor/data-harbor-trivy-0（5Gi）、harbor/harbor-jobservice（1Gi）、squid/registry-cache-squid-cache-0（200Gi）、squid/cache-squid-cache-1（200Gi）、squid/cache-squid-cache-0（200Gi）、squid/registry-cache-squid-cache-1（200Gi） |
| `cf5c6fef…` | 4 | 0 | argo/pvc-computingactiontest-op-plugin-0731（1.2Ti）、argo/pvc-perform-compare（1.2Ti）、sfs-local-mount/pvc-sfs-turbo-local-mount.cf5c6fef-ab67-11f1-b6fa-fa16412f71d0（1.2Ti）、sfs-test/pvc-test-normal（1.2Ti） |
| `6a6b9cc9…` | 3 | 0 | cann/pvc-cann（1.2Ti）、memcache/pvc-ascend-memcache（1.2Ti）、memfabric-hybrid/pvc-ascend-memfabric-hybrid（1.2Ti） |
| `d5fa7449…` | 2 | 0 | argo/pvc-sharesfstest（1.2Ti）、shared-sfs/pvc-shared-sfs-turbo（1.2Ti） |

**独立盘 / 其他 PVC（11 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | sfs-test | pvc-test-mount | Bound | 1.2Ti | - | local·local |
| 2 | milvus | data-my-release-etcd-0 | Bound | 10Gi | csi-disk | disk·disk |
| 3 | milvus | data-my-release-etcd-1 | Bound | 10Gi | csi-disk | disk·disk |
| 4 | milvus | data-my-release-etcd-2 | Bound | 10Gi | csi-disk | disk·disk |
| 5 | milvus | export-my-release-minio-0 | Bound | 500Gi | csi-disk | disk·disk |
| 6 | milvus | export-my-release-minio-1 | Bound | 500Gi | csi-disk | disk·disk |
| 7 | milvus | export-my-release-minio-2 | Bound | 500Gi | csi-disk | disk·disk |
| 8 | milvus | export-my-release-minio-3 | Bound | 500Gi | csi-disk | disk·disk |
| 9 | milvus | my-release-milvus | Bound | 50Gi | csi-disk | disk·disk |
| 10 | milvus | milvus-pvc | Bound | 10Gi | csi-sfs | nas·5f873561… |
| 11 | argo | pvc-testspeed-1 | Bound | 1.2Ti | csi-sfsturbo | sfsturbo·8cf653e6…（absolute） |

### 4.8 aiframework — ascend-aiframework

kubeconfig `~/.kube/configs/aiframework-kubeconfig.yaml` ｜ `cn-north-12` ｜ nginx 布局 `-new` ｜ PVC **42** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `c461cb6e…` | 16 | 0 | alibaba-roll-liqo/alibaba-roll-liqo-cn12-001-v2（1.2Ti）、areal-project-areal/areal-project-areal-shared-v3（1.2Ti）、areal-project-areal/areal-project-areal-cn12-001-v2（1.2Ti）、ascend-pytorch/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-sglang/ascend-sglang-cn12-001-v2（1.2Ti）、model-download/pvc-efs-test（14.4Ti）、monitoring/pvc-cache-cleanup-big（14.4Ti）、sgl-project-sgl-kernel-npu/sgl-project-sgl-kernel-npu-liqo-v2（1.2Ti）、tile-ai-tilelang-mlir-ascend-liqo/tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2（1.2Ti）、triton-ascend-liqo/triton-ascend-liqo-cn12-001-v2（1.2Ti）、verl-project-liqo/verl-project-liqo-cn12-001（1.2Ti）、verl-project-liqo/verl-project-liqo-cn12-001-v2（1.2Ti）、vllm-ascend-800i-aiframe/vllm-ascend-800i-aiframe（1.2Ti）、vllm-ascend-vllm-ascend-recipes/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project-vllm-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project-vllm-omni/vllm-project-vllm-omni-cn12-001-v2（1.2Ti） |
| `9ffa8aa5…` | 4 | 0 | ascend/ascend-pytorch-v1（1.2Ti）、monitoring/pvc-cache-cleanup-areal（1.2Ti）、monitoring/pvc-cache-cleanup-pytorch（1.2Ti）、vllm-project-vllm-ascend/nv-action-vllm-benchmarks-v2（1.2Ti） |
| `ba20b346…` | 21 | 18 | ascend-gha-runners/ascend-gha-runners-pytorch（200Gi）、git-cdn/git-cdn-workdir（200Gi）、nginx-pypi-cache/pypi-cache-data-volume（1Ti） |

**独立盘 / 其他 PVC（1 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | monitoring | grafana-v10-pvc | Bound | 5Gi | csi-disk-topology | disk·disk |

### 4.9 mind-third-ci — ascend-mind-third-ci（hb-003-verl）

kubeconfig `~/.kube/configs/ascend-mind-third-ci-kubeconfig.yaml` ｜ `cn-north-12` ｜ nginx 布局 `-new` ｜ PVC **45** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `cc8060b8…` | 14 | 0 | alibaba-roll-liqo/alibaba-roll-liqo-cn12-001-v2（1.2Ti）、areal-project-areal/areal-project-areal-shared-v3（1.2Ti）、areal-project-areal/areal-project-areal-cn12-001-v2（1.2Ti）、ascend-pytorch/gy005-az5-vllm-ascend-v2（1.2Ti）、ascend-sglang/ascend-sglang-cn12-001-v2（1.2Ti）、model-download/pvc-efs-44t（43.9Ti）、sgl-project-sgl-kernel-npu/sgl-project-sgl-kernel-npu-liqo-v2（1.2Ti）、tile-ai-tilelang-mlir-ascend-liqo/tile-ai-tilelang-mlir-ascend-liqo-cn12-001-v2（1.2Ti）、triton-ascend-liqo/triton-ascend-liqo-cn12-001-v2（1.2Ti）、verl-project-liqo/verl-project-liqo-cn12-001-v2（1.2Ti）、vllm-ascend-800i-mind/vllm-ascend-800i-mind-v2（1.2Ti）、vllm-ascend-vllm-ascend-recipes/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project-vllm-ascend/gy005-az5-vllm-ascend-v2（1.2Ti）、vllm-project-vllm-omni/vllm-project-vllm-omni-cn12-001-v2（1.2Ti） |
| `a8317f79…` | 28 | 19 | ascend-gha-runners/verl-hb003（1.2Ti）、default/sfs-root-probe（1.2Ti）、git-cdn/git-cdn-workdir（200Gi）、monitoring/pvc-cache-cleanup-verl（1.2Ti）、monitoring/pvc-cache-cleanup-vllm（1.2Ti）、nginx-pypi-cache/pypi-cache-data-volume（1Ti）、verl-project/verl-hb003（1.2Ti）、verl-project-liqo/verl-src-old-data（1.2Ti）、vllm-project-vllm-ascend/nv-action-vllm-benchmarks-v2（1.2Ti） |
| `19fa9411…` | 3 | 0 | model-download/pvc-efs-test（14.4Ti）、monitoring/pvc-cache-cleanup-dl（14.4Ti）、verl-project-liqo/verl-project-liqo-cn12-001（1.2Ti） |

### 4.10 sh-001 — openmerlin-sh-001-cluster

kubeconfig `~/.kube/configs/openmerlin-sh-001-cluster-kubeconfig` ｜ `-` ｜ nginx 布局 `-new hostPath` ｜ PVC **0** 个

集群无 PVC：runner 工作盘/缓存走 hostPath `/mnt/share`（NFS suzblue），nginx 走 hostPath `/data/nginx-cache`。见 §2 附表 suzblue 行。

### 4.11 sh-002 — sh-002

kubeconfig `~/.kube/configs/sh-002-kubeconfig` ｜ `-` ｜ nginx 布局 `-new` ｜ PVC **6** 个

| 共享盘 | 本集群 PVC 数 | 其中工作卷 `-work`×64Gi | 持久卷（ns/name·容量） |
|---|---|---|---|
| `179.60.1…` | 5 | 0 | ascend-gha-runners/vllm-ascend-share-pvc-test（1.2Ti）、ascend-pytorch/ascend-pytorch-share-pvc（1.2Ti）、sgl-kernel-npu/sgl-project-sgl-kernel-npu-share-pvc（1.2Ti）、sgl-project/sgl-project-sglang-share-pvc（1.2Ti）、triton-ascend/ascend-triton-ascend-share-pvc（1.2Ti） |

**独立盘 / 其他 PVC（1 个）**，每 PVC 一块物理盘或本机 local，无跨租户共享：

| # | Namespace | PVC | Phase | 容量 | StorageClass | 后端 |
|---|---|---|---|---|---|---|
| 1 | nginx-pypi-cache | pypi-cache-data-volume | Pending | 1Ti | sfsturbo-subpath-sc | 未绑定 |

## 5. 采集方法（复现）

```bash
# 只读。逐集群 dump：
kubectl get pvc -A -o json > pvc.json; kubectl get pv -o json > pv.json
# 盘归组 key（三者按挂法取一）：
#   .spec.csi.volumeAttributes["everest.io/sfsturbo-share-id"]  (absolute-path)
#   .spec.csi.volumeAttributes["everest.io/volume-id"]           (subpath)
#   .spec.nfs.server                                              (static NFS)
# live max_size：
kubectl get deploy pypi-cache-deployment -n nginx-pypi-cache -o jsonpath='{.spec.template.spec.volumes[?(@.configMap)].configMap.name}'
kubectl get cm <CM> -n nginx-pypi-cache -o json | jq -r '.data[]' | grep -oE 'keys_zone=\w+|max_size=\w+'
```

---
*生成：2026-09-18 ｜ 只读采集 ｜ 配套：[`ascend-ci-shared-disk-audit.md`](ascend-ci-shared-disk-audit.md)（盘内实际占用 du 盘点）*
