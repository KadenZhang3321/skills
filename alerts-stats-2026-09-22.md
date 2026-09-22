# 全集群活跃告警统计

- **快照时间**: 2026-09-22 16:50 (Asia/Shanghai)
- **数据源**: infra-monitoring（CN4）中心 Alertmanager，汇聚全部 14 个集群
- **总览**: 活跃告警原始 846 条；按「告警名 + 集群 + 对象」去重后 **342 条**（critical 58 / warning 283，另有 Watchdog 心跳 1 条不计入）

## 1. 按集群统计

| 集群 | Critical | Warning | 合计 |
|---|---|---|---|
| cn12-001 | 21 | 85 | 106 |
| hk-001 | 6 | 44 | 50 |
| guiyang-006 | 12 | 38 | 50 |
| guiyang-002 | 6 | 26 | 32 |
| guiyang-003 | 5 | 15 | 20 |
| mind-third-ci | 0 | 15 | 15 |
| guiyang-005 | 1 | 13 | 14 |
| aiframework | 0 | 14 | 14 |
| guiyang-001 | 1 | 11 | 12 |
| guiyang-004 | 2 | 9 | 11 |
| wlcb-001 | 0 | 11 | 11 |
| infra-monitoring | 1 | 2 | 3 |
| ascend-mind-third-ci | 2 | 0 | 2 |
| ascend-aiframework | 1 | 0 | 1 |
| **合计** | **58** | **283** | **341** |

## 2. 按告警类型统计

| 告警名 | 级别 | 数量 | 涉及集群 | 说明 |
|---|---|---|---|---|
| KubeJobFailed | warning | 118 | guiyang-002×26, hk-001×15, guiyang-005×13, mind-third-ci×10, aiframework×10, guiyang-001×9, cn12-001×9, guiyang-003×8, guiyang-006×8, guiyang-004×6, wlcb-001×4 | K8s Job 执行失败（多为 monitoring 下探测/统计 CronJob） |
| KubePodNotReady | warning | 73 | cn12-001×32, hk-001×21, guiyang-006×12, aiframework×4, mind-third-ci×2, guiyang-004, wlcb-001 | Pod 长时间未 Ready |
| KubeDaemonSetRolloutStuck | warning | 26 | guiyang-006×7, hk-001×7, cn12-001×7, wlcb-001×2, guiyang-004, guiyang-003, mind-third-ci | DaemonSet 滚动更新卡住 |
| NodeFilesystemAlmostOutOfSpace | critical | 18 | cn12-001×18 | 节点文件系统剩余空间不足（>90% warning / >95% critical） |
| NodeFilesystemAlmostOutOfSpace | warning | 18 | cn12-001×18 | 节点文件系统剩余空间不足（>90% warning / >95% critical） |
| NodeFilesystemSpaceFillingUp | warning | 17 | cn12-001×16, guiyang-006 | 节点文件系统按增速预测将快速写满 |
| KubePodCrashLooping | warning | 11 | guiyang-003×6, guiyang-006×2, guiyang-001, cn12-001, wlcb-001 | Pod 持续 CrashLoop |
| RunnerVersionExpiring | critical | 9 | ascend-mind-third-ci, guiyang-004, cn12-001, hk-001, ascend-aiframework, guiyang-006, guiyang-001, guiyang-003, guiyang-005 | GitHub Runner 版本超过 30 天未更新，即将被拒绝执行 job |
| SharedDiskMountFailed | critical | 9 | guiyang-003×4, guiyang-002×4, ascend-mind-third-ci | SFS Turbo 共享盘拨测挂载/读取失败（水位不可知） |
| ListenerCrashLooping | critical | 7 | guiyang-006×7 | ARC listener pod 持续崩溃重建（约 2 分钟一次） |
| KubeDeploymentReplicasMismatch | warning | 6 | guiyang-006×3, wlcb-001, cn12-001, guiyang-001 | Deployment 副本数长期不匹配 |
| KubeContainerWaiting | warning | 6 | guiyang-006×4, mind-third-ci, cn12-001 | 容器长时间处于 Waiting 状态 |
| SharedDiskHighUsage | critical | 4 | cn12-001×2, hk-001, guiyang-006 | SFS Turbo 共享盘容量超过 90% 阈值 |
| TargetDown | warning | 2 | hk-001, mind-third-ci | Prometheus 抓取目标掉线 |
| GitHubUnreachable | critical | 2 | guiyang-006, guiyang-002 | 集群无法通过任何路径访问 GitHub（直连+代理均失败，escalation） |
| GitHubProxyUnreachable | critical | 2 | guiyang-002, guiyang-006 | 集群无法通过 gh-proxy clone 代码，CI 任务将全部失败 |
| KubeDaemonSetMisScheduled | warning | 2 | wlcb-001, guiyang-004 | DaemonSet Pod 调度失败 |
| RunnerPodPendingTooLong | critical | 2 | hk-001×2 | Runner Pod Pending 超过 35 分钟 |
| KubeDeploymentRolloutStuck | warning | 1 | guiyang-006 | Deployment 滚动更新卡住 |
| NPUMetricTotalMissing | critical | 1 | hk-001 | 节点 npu-exporter custom_npu_total 无数据（容量监控失明） |
| NPUMetricTotalUsedCountMissing | critical | 1 | hk-001 | 节点 npu-exporter custom_npu_total_used_count 无数据 |
| RunnerUpdateAvailable | critical | 1 | guiyang-006 | runner 版本落后于 GitHub 最新 release |
| CloudAccountUnreachable | critical | 1 | infra-monitoring | 华为云 BSS 账号 API 无法访问（AK/SK 或网络问题） |
| WorkflowRunTooLong | critical | 1 | guiyang-004 | workflow pod 执行超过 2.5 小时，可能卡死占用 NPU/CPU |
| NPUNodeIdleTooLong | warning | 1 | infra-monitoring | NPU 节点长期闲置 |
| KubeCPUOvercommit | warning | 1 | wlcb-001 | 集群 CPU requests 超卖 |
| PrometheusOperatorStatusUpdateErrors | warning | 1 | infra-monitoring | Prometheus Operator 状态更新报错 |

## 3. Critical 告警明细

### 3.1 磁盘/文件系统类

| 告警 | 位置 | 详情 |
|---|---|---|
| NodeFilesystemAlmostOutOfSpace (critical ×18) | cn12-001 节点 192.168.0.48（18 个 sfs-local 挂载点，全部为同一 SFS Turbo 盘 37cbefa6…/ascend-ci-share 的 subpath） | 与 SharedDiskHighUsage（cn12-001 SFS 99%/100%）同源，盘写满后各 subpath 挂载点全部报满 |
| SharedDiskHighUsage ×4 | cn12-001×2 / hk-001 / guiyang-006 | SFS Turbo share 99%、100%、91%、94%，写满将导致 CI 任务与 Pod 挂载失败 |
| SharedDiskMountFailed ×9 | guiyang-003×4 / guiyang-002×4 / ascend-mind-third-ci | SFS 拨测挂载/读取失败，水位不可知（需先排除跨 VPC 误报） |

### 3.2 其他 Critical

| 告警名 | 集群 | 首次触发 (UTC) | 对象 | 摘要 |
|---|---|---|---|---|
| CloudAccountUnreachable | local | 2026-08-28T02:32 |  | 无法访问华为云 BSS 账号 API，请检查云账号 AK/SK 和网络连通性。 |
| GitHubProxyUnreachable | guiyang-002 | 2026-08-28T02:32 |  | 集群 guiyang-002 无法通过 gh-proxy clone 代码（502/超时），持续 5 分钟以上。该集群 runner 强制走代理，CI 任务将全部失败。 |
| GitHubProxyUnreachable | guiyang-006 | 2026-09-02T09:26 |  | 集群 guiyang-006 无法通过 gh-proxy clone 代码（502/超时），持续 5 分钟以上。该集群 runner 强制走代理，CI 任务将全部失败。 |
| GitHubUnreachable | guiyang-002 | 2026-08-28T02:32 |  | 集群 guiyang-002 无法通过任何路径从 GitHub clone 代码（直连和 gh-proxy 均失败）。这是 escalation 告警，通常意味着 GitHubPr… |
| GitHubUnreachable | guiyang-006 | 2026-09-02T09:26 |  | 集群 guiyang-006 无法通过任何路径从 GitHub clone 代码（直连和 gh-proxy 均失败）。这是 escalation 告警，通常意味着 GitHubPr… |
| ListenerCrashLooping | guiyang-006 | 2026-09-22T07:59 | arc-systems linux-aarch64-cpu-4-buildkit-645d8ccc-listener | 集群 guiyang-006 的 listener pod linux-aarch64-cpu-4-buildkit-645d8ccc-listener 在过去 15 分钟内 重建… |
| ListenerCrashLooping | guiyang-006 | 2026-09-22T06:48 | arc-systems linux-aarch64-test-hook-55d9dd97-listener | 集群 guiyang-006 的 listener pod linux-aarch64-test-hook-55d9dd97-listener 在过去 15 分钟内 重建了 11 … |
| ListenerCrashLooping | guiyang-006 | 2026-09-21T23:49 | arc-systems linux-aarch64-test-hook-64478c47-listener | 集群 guiyang-006 的 listener pod linux-aarch64-test-hook-64478c47-listener 在过去 15 分钟内 重建了 11 … |
| ListenerCrashLooping | guiyang-006 | 2026-09-22T05:30 | arc-systems linux-aarch64-a2-10c16g-v-gy006-5f57cf5c-listener | 集群 guiyang-006 的 listener pod linux-aarch64-a2-10c16g-v-gy006-5f57cf5c-listener 在过去 15 分钟内… |
| ListenerCrashLooping | guiyang-006 | 2026-09-21T19:55 | arc-systems linux-aarch64-a2-90c144g-v-gy006-5f57cf5c-listener | 集群 guiyang-006 的 listener pod linux-aarch64-a2-90c144g-v-gy006-5f57cf5c-listener 在过去 15 分钟… |
| ListenerCrashLooping | guiyang-006 | 2026-09-22T03:30 | arc-systems linux-aarch64-a2-5c8g-v-gy006-5f57cf5c-listener | 集群 guiyang-006 的 listener pod linux-aarch64-a2-5c8g-v-gy006-5f57cf5c-listener 在过去 15 分钟内 重… |
| ListenerCrashLooping | guiyang-006 | 2026-09-22T08:51 | arc-systems linux-amd64-cpu-4-buildkit-645d8ccc-listener | 集群 guiyang-006 的 listener pod linux-amd64-cpu-4-buildkit-645d8ccc-listener 在过去 15 分钟内 重建了 … |
| NPUMetricTotalMissing | hk-001 | 2026-09-22T08:51 | 172.16.1.189 | 多集群 NPU 监控：集群 hk-001 项目 参与开源统一资源池-香港-910B3 的节点 172.16.1.189:9101 的 custom_npu_total 已持续 5 … |
| NPUMetricTotalUsedCountMissing | hk-001 | 2026-09-22T08:51 | 172.16.1.189 | 多集群 NPU 监控：集群 hk-001 项目 参与开源统一资源池-香港-910B3 的节点 172.16.1.189:9101 的 custom_npu_total_used_c… |
| RunnerPodPendingTooLong | hk-001 | 2026-09-22T08:31 | xuedinge233 | 集群 hk-001 namespace xuedinge233 中存在 linux runner Pod Pending 超过 35 分钟，请检查节点资源。 |
| RunnerPodPendingTooLong | hk-001 | 2026-09-22T08:23 | vllm-project | 集群 hk-001 namespace vllm-project 中存在 linux runner Pod Pending 超过 35 分钟，请检查节点资源。 |
| RunnerUpdateAvailable | guiyang-006 | 2026-08-28T02:32 |  | 集群 guiyang-006 部署的 runner 版本落后于 GitHub 最新 release。请安排升级，30 天内不更新 GitHub 将拒绝 runner 执行 job。 |
| RunnerVersionExpiring | ascend-aiframework | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 ascend-aiframework 已过 27 天，超期后 runner 将被拒绝执行 wor… |
| RunnerVersionExpiring | ascend-mind-third-ci | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 ascend-mind-third-ci 已过 27 天，超期后 runner 将被拒绝执行 w… |
| RunnerVersionExpiring | cn12-001 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 cn12-001 已过 27 天，超期后 runner 将被拒绝执行 workflow。请立即升… |
| RunnerVersionExpiring | guiyang-001 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 guiyang-001 已过 27 天，超期后 runner 将被拒绝执行 workflow。请… |
| RunnerVersionExpiring | guiyang-003 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 guiyang-003 已过 27 天，超期后 runner 将被拒绝执行 workflow。请… |
| RunnerVersionExpiring | guiyang-004 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 guiyang-004 已过 27 天，超期后 runner 将被拒绝执行 workflow。请… |
| RunnerVersionExpiring | guiyang-005 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 guiyang-005 已过 27 天，超期后 runner 将被拒绝执行 workflow。请… |
| RunnerVersionExpiring | guiyang-006 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 guiyang-006 已过 27 天，超期后 runner 将被拒绝执行 workflow。请… |
| RunnerVersionExpiring | hk-001 | 2026-09-20T14:43 |  | GitHub 要求 runner 版本在最新 release 30 天内更新。集群 hk-001 已过 27 天，超期后 runner 将被拒绝执行 workflow。请立即升级。 |
| SharedDiskHighUsage | cn12-001 | 2026-09-07T04:20 | 37cbefa6-f10c-47e8-a99a-f483887611ef | 集群 cn12-001 的 SFS Turbo 共享存储实例 （share ID: 37cbefa6-f10c-47e8-a99a-f483887611ef，对应华为云控制台 CC… |
| SharedDiskHighUsage | cn12-001 | 2026-09-17T00:49 | 8258ca0d-8dce-4a35-8802-79d10e0f8f9f | 集群 cn12-001 的 SFS Turbo 共享存储实例 （share ID: 8258ca0d-8dce-4a35-8802-79d10e0f8f9f，对应华为云控制台 CC… |
| SharedDiskHighUsage | guiyang-006 | 2026-09-22T05:16 | 172.22.6.2 | 集群 guiyang-006 的 SFS Turbo 共享存储实例 （share ID: 172.22.6.2，对应华为云控制台 CCE「存储 > SFS Turbo」中的实例）容… |
| SharedDiskHighUsage | hk-001 | 2026-09-07T04:16 | 9c241417-584d-403f-9e8f-dab73b5fc66b | 集群 hk-001 的 SFS Turbo 共享存储实例 （share ID: 9c241417-584d-403f-9e8f-dab73b5fc66b，对应华为云控制台 CCE「… |
| SharedDiskMountFailed | ascend-mind-third-ci | 2026-09-11T07:48 | 19fa9411-b0d5-40b6-b2db-f32b178f8cd3 | 集群 ascend-mind-third-ci 的 SFS Turbo 实例（share ID: 19fa9411-b0d5-40b6-b2db-f32b178f8cd3）拨测挂载… |
| SharedDiskMountFailed | guiyang-002 | 2026-09-07T04:16 | 070878d2-7141-11f1-bf3c-fa16412f71d0 | 集群 guiyang-002 的 SFS Turbo 实例（share ID: 070878d2-7141-11f1-bf3c-fa16412f71d0）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-002 | 2026-09-15T02:40 | 7fcef8a8-acc1-11f1-9a9c-fa16445a2e80 | 集群 guiyang-002 的 SFS Turbo 实例（share ID: 7fcef8a8-acc1-11f1-9a9c-fa16445a2e80）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-002 | 2026-09-08T13:46 | d5fa7449-ab88-11f1-8ea6-fa16446e05c1 | 集群 guiyang-002 的 SFS Turbo 实例（share ID: d5fa7449-ab88-11f1-8ea6-fa16446e05c1）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-002 | 2026-09-18T07:17 | 8cf653e6-acc1-11f1-9a9c-fa16445a2e80 | 集群 guiyang-002 的 SFS Turbo 实例（share ID: 8cf653e6-acc1-11f1-9a9c-fa16445a2e80）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-003 | 2026-09-20T12:46 | 0ca03ada-9d51-4b2c-83a4-f03f079a6963 | 集群 guiyang-003 的 SFS Turbo 实例（share ID: 0ca03ada-9d51-4b2c-83a4-f03f079a6963）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-003 | 2026-09-20T12:46 | a3d80a1b-abc7-478e-bc90-c497a7f654ab | 集群 guiyang-003 的 SFS Turbo 实例（share ID: a3d80a1b-abc7-478e-bc90-c497a7f654ab）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-003 | 2026-09-20T12:46 | 39a33a00-3be8-4345-8079-63cf23a44a88 | 集群 guiyang-003 的 SFS Turbo 实例（share ID: 39a33a00-3be8-4345-8079-63cf23a44a88）拨测挂载/读取失败，该盘当… |
| SharedDiskMountFailed | guiyang-003 | 2026-09-20T12:46 | b46afb97-6954-11f1-af0f-fa16412f71d0 | 集群 guiyang-003 的 SFS Turbo 实例（share ID: b46afb97-6954-11f1-af0f-fa16412f71d0）拨测挂载/读取失败，该盘当… |
| WorkflowRunTooLong | guiyang-004 | 2026-09-22T08:25 | sgl-project linux-amd64-cpu-4-mzzt2-runner-mbvcz-workflow | 集群 guiyang-004 命名空间 sgl-project 的 workflow pod linux-amd64-cpu-4-mzzt2-runner-mbvcz-workfl… |

## 4. 要点

1. **cn12-001 是重灾区**（106 条）：SFS Turbo 盘 `37cbefa6…`（ascend-ci-share）已用 99-100%，导致节点 192.168.0.48 上 18 个 subpath 挂载点全部报文件系统临界；挂该盘的 vllm-project、triton-ascend、tile-ai 等约 30 个租户 PVC 共享此容量，写满即 CI 大面积失败。建议扩容或清理。
2. **Runner 版本集体超期**：9 个集群 RunnerVersionExpiring 已触发 27 天（30 天上限），hk-001/cn12-001/贵阳各集群需在 9-23 前后完成 runner 升级，否则 GitHub 将拒绝执行 workflow。
3. **guiyang-006 listener 崩溃**：arc-systems 下 7 个 listener（a2 系列 + buildkit + test-hook）15 分钟内重建 10+ 次，该集群 runner 供给受影响；同集群还有 GitHub(Unreachable)/(ProxyUnreachable) 自 09-02 持续。
4. **guiyang-002 GitHub 通路自 08-28 起中断**（直连+代理均失败），该集群 CI clone 会全部失败。
5. **KubeJobFailed ×118**：绝大多数为各集群 monitoring ns 的探测/统计 CronJob（cloud-account、cert-expiry 等）偶发失败，以及 guiyang-002 default ns ×26，需抽查是否有系统性原因（与其 GitHub 中断相关）。
6. **KubePodNotReady ×73**：主要在 cn12-001/hk-001 的 kube-system（×32/×21），建议核对节点状态。
