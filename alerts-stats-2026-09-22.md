# 全集群 Critical 告警统计（最近 3 天）

- **窗口**: 2026-09-19 17:00 ~ 09-22 17:35 Asia/Shanghai（滚动 72h）
- **数据源**: CN4 中心 Prometheus `ALERTS{severity="critical"}` × Alertmanager 当前活跃集 × 路由配置
- **总览**: 3 天内触发 **436 序列**（fs 按挂载点去重后 26 个真实对象）；按路由拆分：
  - **实际外发邮件**: 进行中 **25** / 窗口内已解决 **170**
  - **黑洞（设计静默）**: 进行中 **31** / 窗口内已解决 **8**
  - （另 CloudAccountUnreachable 1 进行中，按 review 意见不列）

## 1. 外发 · 仍在告警（截至 09-22 17:35）

| 告警名 | 集群 | 进行中对象 | 接收方 | 备注 |
|---|---|---|---|---|
| RunnerVersionExpiring | 8 集群 | 8 | zhangyang(4h) | ⚠️ 已确认误报（规则不比对部署版本），修复在 PR #1782，合入后仅剩 gy006 真旧版 |
| SharedDiskMountFailed | guiyang-002×4、guiyang-003×4、ascend-mind-third-ci×1、cn12-001×1 | 10 | zhangyang(4h) | SFS 拨测挂载失败，水位不可知 |
| SharedDiskHighUsage | cn12-001×2、hk-001×1 | 3 | zhangyang(4h) | 37cbefa6 盘 99% / 8258ca0d 盘 100% / hk 91% |
| GitHubUnreachable + GitHubProxyUnreachable | guiyang-002 | 2 | yinyulin | 自 08-28 中断，72h+ 未恢复 |
| RunnerPodPendingTooLong | hk-001 | 2 | dev+root | vllm-project、xuedinge233 |
| （guiyang-006 全黑洞，见 §3） | | | | |

## 2. 外发 · 窗口内已解决

| 告警名 | 集群 | 对象数 | 累计(h) | 接收方 |
|---|---|---|---|---|
| WorkflowRunTooLong | cn12×48、gy004×34、hk×17、gy005×8、mtci×3 | 110 | 125.0 | dev+root |
| NPUMetricTotalMissing / UsedCountMissing | hk-001、cn12-001、wlcb×5、aiframework、gy001×4 | 24 | 39.2 | datastat（快照时已 resolve，**间歇丢数据未根治**，见 §4） |
| SharedDiskMountFailed | guiyang-001×8、ascend-aiframework、gy005 | 10 | 28.6 | zhangyang(4h) |
| RunnerPodPendingTooLong | cn12×5、hk×2、gy004×3、gy005×2、mtci×3 | 15 | 33.6 | dev+root |
| CertExpiring / CertProbeFailed | guiyang-004 | 2 | 29.8 | dev+root / zhangyang(24h) |
| RunnerImagePullFailed | gy004、gy005、cn12、hk | 4 | 9.2 | dev+root |
| NPU8CardJobWaitTooLong | wlcb | 2 | 4.0 | yinyulin |
| GitHubStatusIncidentOpen / Degraded | hk-001 | 2 | 1.2 | dev+root |
| SharedDiskHighUsage | ascend-aiframework | 1 | 22.8 | zhangyang(4h) |

## 3. 黑洞（设计上不发邮件，39 对象）

### 3.1 NodeFilesystem* × sfsturbo 挂载点（26 对象：进行中 18 / 已解决 8）

路由规则 `alertname=NodeFilesystem.* && device=~.*sfsturbo.* → blackhole`，由 SharedDiskHighUsage 替代上报（§1）。本质仍是 **cn12-001 两块盘满**，一块盘按租户 subpath 挂载点展开（3 天共 26 个挂载点序列，当前 18 个在报）。
> 修正：此前"203 对象"为挂载点×节点序列数口径，虚高。

### 3.2 guiyang-006 集群级黑洞（13 对象，全部仍在告警）

| 告警名 | 对象 | 累计(h) |
|---|---|---|
| ListenerCrashLooping | arc-systems 7 个 listener | 529.6 |
| GitHubUnreachable / GitHubProxyUnreachable | 1+1 | 144.0 |
| RunnerUpdateAvailable | 1 | 72.0 |
| RunnerVersionExpiring | 1 | 42.3 |
| SharedDiskHighUsage (172.22.6.2 94%) | 1 | 3.8 |

⚠️ 该集群"一律不外发"导致这些 critical 3 天静默。若非有意下线，建议重新评估黑洞路由。

## 4. 丢失指标根因（NPUMetric*，接收方 datastat-email）

### 4.1 hk-001 / 172.16.1.189（主问题）

- 中心侧 3 天仅收到 **724/4320** 点（缺 42%），4~43 分钟连续空洞全天分布；快照时点暂时 resolve，但机制问题未除仍会复发
- 同机 node-exporter `:9100` 满量 → 节点/网络正常；exporter Pod 0 重启；日志大量抓取方 `ConnectionReset`
- 根因：`merged_server.py` /metrics 串行渲染 `nsenter→npu-smi`(10s 子进程超时) + K8s/mindx API(15s)；mindx-dl(5s 轮询)+clabagent+device-plugin 并发压驱动，NPU 任务时 npu-smi 间歇 >10s → 超 scrape_timeout(10s) 抓取被掐
- 放大缺陷①：agent `keep custom_npu_.*` 连 `up=0` 一起丢 → 中心只见序列消失，TargetDown 不报
- 放大缺陷②：规则要求"近 6h 曾上报" → 缺失 >6h 自动 resolve，42% 缺失只报出 13h
- cn12 192.168.0.109：同类间歇，有 `custom_npu_scrape_error=1` 打点；wlcb/gy001/aiframework 瞬时抖动系 exporter 发布

### 4.2 建议

1. npu-exporter job `scrape_timeout` 提至 30s，或两模块并行渲染 + npu-smi 短 TTL 缓存
2. agent keep 正则改 `up|custom_npu_.*`
3. 去掉"6h 曾上报"前置，补 30min absent 长缺失告警
4. 1.189 主机侧错峰三方 npu-smi 轮询

## 5. 要点

1. **需要动手**：cn12 两块 SFS 盘扩容/清理（盘满进行中）、guiyang-002/003 SFS 拨测挂载失败共 8 盘、guiyang-002 GitHub 通路（yinyulin 侧跟进）、runner 版本修复 PR #1782 合入。
2. **观测盲区**：guiyang-006 集群黑洞 + fs 黑洞 + NPUMetric"6h 前置"三处叠加，使真实问题（listener 崩溃 529h、NPU 监控 42% 失明）在邮件里几乎不可见。
