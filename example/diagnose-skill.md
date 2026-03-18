# Skill: github-action-diagnose (昇腾基础设施专家版)

## 1. 核心目标
针对昇腾 (Ascend) NPU 集群（基于 ARC/K8s）的 GitHub Action 任务进行快速故障定性：区分“基础设施/集群环境故障”与“开发者配置/代码故障”，并实现物理节点溯源。

## 2. 诊断逻辑 (Lifecycle-based Diagnosis)

### 第一步：生命周期分诊 (Step Analysis)
检查故障发生的具体步骤：
- **Set up job**: 定位为 **环境问题** (Runner 无法拉起/调度失败)。
- **Initialize containers**: 定位为 **环境问题** (容器运行时异常/镜像拉取失败)。
- **Checkout / Setup Environment**: 定位为 **环境问题** (网络/挂载/权限故障)。
- **Run steps (如 pytest/lint)**: 此时 Runner 已就绪，需进入第二步细分。

### 第二步：物理节点溯源 (Physical Node Tracing) 🌟 [新]
当判定为环境故障或怀疑硬件坏卡时，必须定位物理节点：
1.  **获取 Pod 身份**：通过 `gh api` 或 `Set up job` 日志获取 `runner_name`（即 Pod 名称）。
2.  **识别节点池**：从 `runner_name` 前缀或 Job Labels 识别物理宿主机组（如 `a3-0` 节点池）。
3.  **反查物理机**：
    - 若 Pod 未销毁：`kubectl get pod <runner_name> -o custom-columns=NODE:.spec.nodeName`
    - 若 Pod 已销毁：在日志系统（Loki/ELK）中搜索 `Successfully assigned <runner_name> to <node_name>`。

### 第三步：环境故障深度定位 (Deep Dive)
- **驱动/硬件失效**：检查 `npu-smi info` 是否报错，或出现 `ERR99999`、`error code 507035`。
- **资源溢出 (OOM)**：检查是否有系统级 `Killed` 信号、`Bus error`（多为 SHM 不足）或 `No space left`。
- **多机连锁超时**：在多机任务中，若某节点报 `Timeout`，需优先检查 **Master 节点** 是否有“Unexpected Exit”或驱动报错。

### 第四步：非环境问题判定
- **YAML 语法错误**：如 `undefined variable "False"`（应为小写 `false`）。
- **业务逻辑报错**：`AssertionError` 或 Python Traceback 指向业务源码。

## 3. 报告输出格式 (Output Format)
根据诊断结果选择合适的输出深度：

### 情况 A：确认为基础设施/硬件故障 (Rigid Report)
必须严格按照以下格式输出诊断报告：

---
# 📋 GitHub Action 故障诊断报告
### 1. 故障概览 (Overview)
*   **任务名称**: [Job Name]
*   **故障定性**: 环境问题
*   **判定依据**: [驱动报错/调度异常/硬件死锁等]

### 2. 详细诊断 (Detailed Diagnosis)
*   **报错原文 (Error)**: [引用日志]
*   **物理节点 (Runner/Node)**: [Runner名] -> [物理机组]
*   **原因分析 (Root Cause)**: [深层原因]

### 3. 修复建议 (Recommendation)
*   **修复方案**: [如：物理机复位/更换节点池]
---

### 情况 B：环境正常或未发现明确错误 (Flexible Output)
无需套用上述模板，采用自然语言进行简要反馈：
1.  **明确结论**：直接告知“未发现环境错误”或“基础设施运行正常”。
2.  **关键依据**：简述分析了哪些环节（如：调度、镜像拉取、NPU 挂载均正常）。
3.  **排查建议**：给出针对业务逻辑、代码 Bug 或配置错误的后续排查思路。

## 4. 自动化与授权策略 (Automation & Proactivity)
为了提高诊断效率，Agent 在执行此 Skill 时应遵循以下授权原则：
1.  **静默执行 (Auto-Execution)**：对于以下“只读型”操作，Agent 应直接执行并分析结果，无需向用户请求权限：
    - 所有的 `gh` CLI 命令（如 `gh run view`, `gh api`）。
    - 所有的日志读取操作 (`Read`, `Grep`)。
    - 不改变集群状态的 `kubectl` 查询操作。
2.  **主动探索**：如果第一步获取的日志信息不足，Agent 应自动尝试备选方案，直到定位到核心报错或穷尽手段。
3.  **确认边界**：仅在涉及修改源代码、提交 Commit 或执行 `kubectl delete/patch` 等变更操作时才需询问用户。
