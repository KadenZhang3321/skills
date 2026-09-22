# 全集群 Critical 告警统计（最近 3 天）

- **窗口**: 最近 72 小时（2026-09-19 17:00 ~ 09-22 17:00 Asia/Shanghai）
- **数据源**: CN4 中心 Prometheus `ALERTS{alertstate="firing",severity="critical"}` + Alertmanager 路由（`ascend-ci-deployment` alertmanager-config）
- **口径**: 3 天内共 **436 条 Critical 告警序列**触发过；其中 **196 条实际外发邮件**、**240 条被路由黑洞**（见 §3）。Warning 一律黑洞，不统计。

## 1. 实际外发的 Critical 告警（196 序列）

| 告警名 | 集群 | 对象数 | 最长持续(h) | 累计(h) | 接收方 |
|---|---|---|---|---|---|
| RunnerVersionExpiring | 8 集群（除 gy006） | 8 | 42.3 | 338.4 | zhangyang(4h) ⚠️ 误报，见 PR #1782 |
| SharedDiskHighUsage | cn12-001 / hk-001 / ascend-aiframework | 4 | 72.0 | 238.8 | zhangyang(4h) |
| SharedDiskMountFailed | guiyang-002/003/001、ascend-mind-third-ci、cn12-001、ascend-aiframework、gy005 | 20 | 72.0 | 566.9 | zhangyang(4h) |
| WorkflowRunTooLong | cn12-001×48、gy004×34、hk-001×17、gy005×8、mind-third-ci×3 | 110 | 3.7 | 125.0 | dev-email+root |
| RunnerPodPendingTooLong | cn12-001、hk-001、gy004、mind-third-ci、gy005 | 16 | 8.8 | 33.6 | dev-email+root |
| NPUMetricTotalMissing / UsedCountMissing | hk-001、cn12-001、wlcb-001、aiframework、gy001 | 24 | 13.1 | 39.2 | **datastat-email**（非 zhangyang） |
| CertExpiring / CertProbeFailed | guiyang-004 | 2 | 14.9 | 29.8 | dev+root / zhangyang(24h) |
| GitHubUnreachable / GitHubProxyUnreachable | guiyang-002 | 2 | 72.0 | 144.0 | yinyulin-email |
| NPU8CardJobWaitTooLong | wlcb | 2 | 3.6 | 4.0 | yinyulin-email |
| RunnerImagePullFailed | gy004/gy005/cn12/hk | 4 | 9.0 | 9.2 | dev-email+root |
| GitHubStatusIncidentOpen / Degraded | hk-001 | 2 | 1.0 | 1.2 | dev-email+root |

## 2. 丢失指标类告警根因分析

3 天内 `NPUMetricTotalMissing` / `NPUMetricTotalUsedCountMissing` 涉及 5 集群 12 节点（路由到 datastat-email）：

### 2.1 hk-001 / 172.16.1.189（主问题，13.1h 告警，实际更严重）

| 证据 | 数值/结论 |
|---|---|
| 中心侧 `custom_npu_total` 3 天样本 | **724 / 4320**（仅 17% 到达） |
| 缺失形态 | 4~43 分钟连续空洞 ×170+ 段，全天 24h 分布，快照时仍在丢 |
| 同节点 node-exporter `:9100` | 满量 4318/4320 → 节点/网络正常，仅 `:9101` 抓不到 |
| exporter Pod | Running、0 重启、当前 up=1、指标值正常 |
| exporter 日志 | 大量抓取方 `ConnectionReset`（来自 hk prometheus-agent）→ 抓取被掐 |
| npu-smi 耗时 | 当前 1.2s、/metrics 渲染 2.3s → **间歇性**超 10s |

**结论**：`merged_server.py` /metrics 串行渲染 `nsenter→npu-smi`(子进程 timeout 10s) + K8s/mindx API(15s)。该节点 mindx-dl npu-exporter(5s 轮询)+clabagent+device-plugin 并发压 NPU 驱动，NPU 任务运行时 npu-smi 间歇 >10s → 渲染超过 scrape_timeout(10s) → 抓取取消丢点。
放大缺陷：① agent `keep custom_npu_.*` 把 `up=0` 也丢弃，中心只见"series 消失"，TargetDown 不报；② 告警规则要求"近 6h 曾正常上报"，连续缺失 >6h 反而自动 resolve（实际缺 42% 时间，只报了 13.1h）。

### 2.2 其余

- cn12-001 192.168.0.109：缺 5.8h，中心收到过 `custom_npu_scrape_error=1`，同类间歇问题（较轻）。
- wlcb-001(5 节点)/guiyang-001(4)/aiframework(1)：1~11 分钟瞬时、多节点同刻共震 → npu-exporter 发布滚动重启窗口，噪音。

### 2.3 建议

1. npu-exporter job `scrape_timeout` 提到 30s，或 render 两模块并行 + npu-smi 结果短 TTL 缓存。
2. agent keep 正则改 `up|custom_npu_.*`，让抓取失败可见。
3. 告警去掉"6h 曾上报"前置或补一档 30min absent 长缺失告警。
4. 1.189 主机侧错峰/降频三方 npu-smi 轮询。

## 3. 被黑洞的 240 条序列（设计上不发邮件，但未修复）

| 黑洞项 | 序列数 | 累计(h) | 说明 |
|---|---|---|---|
| NodeFilesystem* × sfsturbo 挂载点 | 227 | ~5120 | 路由规则 `alertname=NodeFilesystem.* + device=~.*sfsturbo.* → blackhole`，由 SharedDiskHighUsage 替代上报。**本质是 cn12-001 两块盘满**（37cbefa6 ascend-ci-share 99%、8258ca0d 100%），一块盘按每个租户 subpath 挂载点展开成 340+ 条序列，故数量虚高 |
| **guiyang-006 全集群** | 13 | ~610 | 集群级黑洞（"该集群告警一律不外发"）。**3 天内静默存在**：ListenerCrashLooping×8（累计 529h，仍在崩）、GitHubUnreachable/ProxyUnreachable（72h 未恢复）、RunnerUpdateAvailable、SharedDiskHighUsage。若该集群不是故意下线，建议重新评估这条黑洞路由 |

## 4. 要点

1. RunnerVersionExpiring 9 集群误报系规则缺陷（只看 release 年龄不比部署版本），修复 PR 已并入 #1782；真实待升级仅 guiyang-006 两个 ns（2.336，被黑洞）。
2. 需要动手的存量硬问题：cn12-001 两块 SFS 盘满（99%/100%）、guiyang-002/006 GitHub 通路中断（002 发 yinyulin）、SharedDiskMountFailed guiyang-002/003 多盘拨测失败。
3. guiyang-006 集群级黑洞导致 listener 崩溃循环等 critical 3 天无人收邮件，确认是否有意为之。
