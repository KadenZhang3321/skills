# sh-001 (上海集群) 参考配置

本目录存放上海集群中**不在 ArgoCD/ascend-ci-deployment 管理范围内**的组件配置，供参考和对照。

> 这些文件对应集群当前实际运行状态，但不是由 ArgoCD 自动同步的。如有变更需手动 apply。

## 文件列表

| 文件 | 说明 | 在集群上的管理方式 |
|------|------|-------------------|
| `ascend-device-plugin-daemonset.yaml` | Ascend Device Plugin DaemonSet（v26.1.0.beta.2） | **手动 kubectl apply** |
| `vnpu.cfg` | VNPU 虚拟设备配置（每节点 `/etc/vnpu.cfg`） | 节点本地文件 |
| `volcano-scheduler-configmap.yaml` | Volcano 调度器配置 | **ascend-ci-deployment 仓库管理**（`manifests/volcano-controller-sh-001/`），此处为备份 |

## 已在 ascend-ci-deployment 中管理的组件

| 组件 | 仓库路径 | ArgoCD App |
|------|---------|------------|
| Volcano Controller/Scheduler/Admission | `manifests/volcano-controller-sh-001/` | `volcano-controller-sh-001` |
| NPU Scheduler (ARCSync) | `manifests/scheduler-plugins-new/` | `sh-001-npu-scheduler` |
| Runner Pod Templates (a5-2/4/8) | `projects/vllm-project/vllm-ascend/config-sh-001/` | `vllm-project-vllm-ascend-config-sh-001` |
| Runner Scale Sets | `projects/vllm-project/vllm-ascend/linux-aarch64-a5-{2,4,8}/` | 对应 ArgoCD App |

## Device Plugin 版本历史

| 日期 | 版本 | volcanoType | 备注 |
|------|------|------------|------|
| 2026-07-17 | v6.0.0 / v7.0.RC1 / v26.0.1 | 未知 | 集群搭建初期，多次切换 |
| 2026-07-17 ~ 2026-07-30 | v26.1.0.beta.2 | **true** | 导致 1/2/4 卡 pod UnexpectedAdmissionError |
| 2026-07-30 ~ 现在 | v26.1.0.beta.2 | **false** | 修复后正常运行 |

详见 `../../../../sh-001-all-issues.md` 问题 #10。
