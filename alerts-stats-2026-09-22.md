# 全集群 Critical 告警统计（近 3 天）

- **窗口**: 2026-09-19 ~ 2026-09-22（3 天，快照 09-22 17:30 Asia/Shanghai）
- **数据源**: infra-monitoring（CN4）中心 Prometheus `ALERTS{alertstate="firing",severity="critical"}`，覆盖全部 14 个集群
- **口径**: 仅 Critical（Warning 不统计）；Watchdog 心跳除外；时长按规则 30s 评估周期折算
- **规模**: 3 天内共 **436 条 Critical 告警序列** 触发过

## 1. Critical 告警统计（按告警名 × 集群）

| 告警名 | 集群 | 对象数 | 最长持续触发(h) | 累计触发时长(h) |
|---|---|---|---|---|
| CloudAccountUnreachable | infra-monitoring | 1 | 72.0 | 72.0 |
| GitHubProxyUnreachable | guiyang-002 | 1 | 72.0 | 72.0 |
| GitHubProxyUnreachable | guiyang-006 | 1 | 72.0 | 72.0 |
| GitHubUnreachable | guiyang-002 | 1 | 72.0 | 72.0 |
| GitHubUnreachable | guiyang-006 | 1 | 72.0 | 72.0 |
| RunnerUpdateAvailable | guiyang-006 | 1 | 72.0 | 72.0 |
| SharedDiskHighUsage | cn12-001 | 2 | 72.0 | 144.0 |
| SharedDiskHighUsage | hk-001 | 1 | 72.0 | 72.0 |
| SharedDiskMountFailed | ascend-mind-third-ci | 1 | 72.0 | 72.0 |
| SharedDiskMountFailed | guiyang-002 | 4 | 72.0 | 288.0 |
| ListenerCrashLooping | guiyang-006 | 8 | 70.5 | 529.6 |
| NodeFilesystemAlmostOutOfSpace | cn12-001 | 203 | 54.0 | 4817.9 |
| SharedDiskMountFailed | guiyang-003 | 4 | 44.5 | 178.2 |
| RunnerVersionExpiring | 9 个集群各 1 | 9 | 42.3 | 380.7 |
| NodeFilesystemAlmostOutOfSpace | guiyang-005 | 1 (/root/.cache) | 24.0 | 24.0 |
| SharedDiskHighUsage | ascend-aiframework | 1 | 22.8 | 22.8 |
| CertExpiring / CertProbeFailed | guiyang-004 | 1 | 14.9 | 14.9×2 |
| **NPUMetricTotalMissing** | hk-001 / cn12-001 / wlcb-001 / aiframework / guiyang-001 | 12 | 13.1 | 19.6 |
| **NPUMetricTotalUsedCountMissing** | （同上 5 集群） | 12 | 13.1 | 19.6 |
| NodeFilesystemSpaceFillingUp | cn12-001 / guiyang-005 | 23 | 11.6 | 253.8 |
| RunnerImagePullFailed | guiyang-004×1, gy005/cn12/hk×1 | 4 | 9.0 | 9.2 |
| RunnerPodPendingTooLong | hk-001×4, cn12-001×5, guiyang-004×3, mind-third-ci×3, guiyang-005×2 | 17 | 8.8 | 39.3 |
| WorkflowRunTooLong | guiyang-004×34, cn12-001×48, hk-001×17, guiyang-005×8, mind-third-ci×3 | 110 | 3.7 | 125.0 |
| NPU8CardJobWaitTooLong | wlcb | 2 | 3.6 | 4.0 |
| GitHubStatusIncidentOpen / Degraded | hk-001 | 2 | 1.0 | 1.2 |
| SharedDiskMountFailed | guiyang-001×8, cn12-001×1, gy005×1, ascend-aiframework×1 | 11 | 3.8 | 28.6 |
| SharedDiskHighUsage | guiyang-006 | 1 | 3.8 | 3.8 |

> 持续 72h = 3 天内从未恢复的存量告警（GitHub 通路、SFS 盘满、listener 崩溃等）。

## 2. 丢失指标类告警根因分析

3 天内 `NPUMetricTotalMissing` / `NPUMetricTotalUsedCountMissing`（critical）共涉及 5 个集群 12 节点，逐类排查结论：

### 2.1 hk-001 / 172.16.1.189（主问题，13.1h 告警，实际更严重）

| 证据 | 数值/结论 |
|---|---|
| 中心侧 `custom_npu_total` 3 天样本 | **724 / 4320**（60s 抓取，仅 17% 到达），`up` 同为 730 |
| 缺失形态 | 4~43 分钟连续空洞 ×170+ 段，覆盖 09-19 17:19 起全天 24h，**快照时仍在丢** |
| 同节点 node-exporter `:9100` | 4318/4320 满量 → 节点网络、K8s 正常，仅 `:9101` 抓不到 |
| exporter Pod（npu-exporter-ascend） | Running、0 重启、当前 up=1、指标值正常（total=8） |
| exporter 日志 | 大量 `ConnectionResetError by peer`（来自抓取方 100.125.140.170，即 hk prometheus-agent）→ 抓取方主动掐连接 |
| npu-smi / 自渲染耗时 | 当前 1.2s / 2.3s，正常 → **间歇性**变慢 |

**结论**：`merged_server.py` 的 `/metrics` 渲染串行调用 ①`nsenter → npu-smi`（子进程 timeout 10s）②K8s/mindx HTTP API（timeout 15s）。该节点上 mindx-dl npu-exporter（5s 轮询）、clabagent npu-exporter、device-plugin 并发压 NPU 驱动，NPU 任务（dmesg 可见 ray 进程）运行期间 npu-smi 间歇 >10s，整次渲染超过 prometheus 默认 scrape_timeout(10s) → 抓取被取消，本轮数据点丢失；驱动锁竞争持续数分钟即形成分钟级空洞。

两个放大问题的机制缺陷：
1. hk agent 的 npu-exporter job `metric_relabel_configs: keep custom_npu_.*` 把失败标记 `up=0` 也丢弃 → 中心侧看不到抓取失败，只表现为"series 凭空消失"，TargetDown 也不报，排障只能靠 count_over_time。
2. 告警规则要求「近 6 小时内曾正常上报」→ 连续缺失 >6h 后告警反而自行 resolve（该节点实际缺 42% 的点，告警却只报 13.1h）。

### 2.2 cn12-001 / 192.168.0.109（910C560T）

指标缺失约 719 分钟（3601/4320），中心侧收到过 1 个 `custom_npu_scrape_error=1` → 同类间歇渲染异常（exporter 显式报错而非静默丢点），单点 5.8h 告警。

### 2.3 wlcb-001（5 节点）/ guiyang-001（4 节点）/ aiframework（1 节点）

每节点仅 2~22 个点（1~11 分钟）且多节点同刻共震 → npu-exporter-ascend **版本发布/滚动重启**窗口（当前镜像 `main-bf49068`，Pod 重建约 5 天前），属瞬时噪音，无需处理。

### 2.4 建议

1. npu-exporter job `scrape_timeout` 提到 30s（覆盖 npu-smi 10s 子进程超时）；或 render 内两模块**并行**渲染 + npu-smi 结果短 TTL 缓存。
2. agent 侧 keep 正则改为 `up|custom_npu_.*`，让抓取失败以 `up=0` 可见。
3. 丢失指标告警去掉「6h 内曾上报」前置条件（或加一档 30 分钟 absent 长缺失告警），否则长期缺失反而静默。
4. 1.189 主机侧：检查 mindx-dl/clabagent 双 npu-exporter 与自定义 exporter 三方轮询 npu-smi 的必要性，错峰或降频。

## 3. 要点

1. **存量硬骨头 72h 未恢复**：guiyang-002/006 GitHub 通路中断（proxy+直连）、cn12-001 SFS 盘满（ascend-ci-share 99-100%，203 个挂载对象报满）、guiyang-006 8 个 ARC listener 崩溃循环、CloudAccountUnreachable。
2. **Runner 版本 9 集群超期 42h+**（30 天红线），临近 GitHub 拒绝执行 job，需立即升级。
3. 丢失指标的真实损失面比告警数字大：hk 1.189 三天 42% 监控失明，靠现行规则只能看到 13h，建议按 2.4 修复观测链路。
