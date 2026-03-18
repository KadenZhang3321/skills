---
name: ci-diagnosis
description: GitHub Action CI 失败自动诊断，专为昇腾（Ascend）NPU 集群（ARC/K8s）基础设施设计。当用户提到 CI 失败、流水线挂掉、CI 报错、构建失败、测试失败、PR CI 不过、CI 排队超时、nightly 失败、runner 异常等情况时立即触发。自动分析日志、定位物理节点、分类根因（基础设施/代码Bug/精度回归）、识别责任方，将诊断报告写入文件。即使用户只是粘贴了一段错误日志或 CI 链接，也应触发此 skill。
compatibility:
  tools:
    - Bash
    - Read
    - Write
    - Glob
    - Grep
---

# CI 故障自动诊断 Skill

## 核心原则

- **静默执行**：直接运行所有只读操作（`gh` CLI、日志读取、`kubectl` 查询），不要逐步询问权限
- **先跑后说**：收集完所有信息后，一次性生成完整报告
- **写入文件**：诊断结果写入 skill 目录下的 `reports/diagnosis-<run_id>.md`，目录不存在时先 `mkdir -p reports/`；对话中只输出简短摘要
- **责任明确**：每个问题必须标注责任方（基础设施团队 / PR 作者）
- **仅在变更操作前确认**：修改代码、提交 commit、执行 `kubectl delete/patch` 才需询问

---

## Step 0：补全上下文（一次性确认）

如用户未提供，统一问一次：
1. 仓库（默认 `vllm-project/vllm-ascend`）
2. CI Run ID 或 URL
3. PR 号（如果是 PR 触发）
4. 集群 kubeconfig（需要 kubectl 溯源时）

用户已提供日志内容时直接开始分析，无需等待完整信息。

---

## Step 1：静默收集上下文

**优先使用脚本**，一次命令完成所有数据收集，减少重复 API 调用和日志噪声：

```bash
bash <skill目录>/scripts/fetch-run.sh <run_id> [owner/repo]
# 默认 repo 为 vllm-project/vllm-ascend
```

脚本自动完成：
1. `gh run view` → Run 概览 + Job 列表 + Annotations（cancelled 原因在此）
2. 所有 `failure` Job 的 runner 名称 + 关键日志（原始 500+ 行 → 预过滤至 ~20 行）
3. `cancelled` Job 标注为"queue 抢占"，不拉日志（节省 token）

**按需补充的命令**（脚本输出不足以定位根因时才用）：

```bash
# 某 Job 的完整原始日志
gh run view --job <job_id> --log --repo <owner/repo>

# PR 变更文件列表
gh pr diff <pr_number> --repo <owner/repo> --name-only
```

---

## Step 2：生命周期快速分诊

根据**失败发生的步骤**做初步判断：

| 失败步骤 | 初步定性 |
|---------|---------|
| `Set up job` | 基础设施 — Runner 调度失败 |
| `Initialize containers` | 基础设施 — 容器运行时异常 |
| `Checkout` / `Install dependencies` | 基础设施 — 网络/挂载/权限 |
| `Run test` / `Build` | **需同时执行 Step 3 和 Step 4**，不可只做其中之一 |

> **重要**：失败在 `Run test` / `Build` 阶段时，必须同时检查环境故障（Step 3）和代码问题（Step 4），不因"看起来是代码问题"而跳过环境检查，也不因"多 Job 同时失败"而跳过代码检查。

**多个 Job 同步以相同步骤失败 → 强烈的基础设施信号**，但仍需完成代码侧的快速排查。

---

## Step 3：物理节点溯源（A 类必做，Run step 失败时也应尝试）

### 3a. 获取 runner_name

从 `Set up job` 日志或 API 获取，格式通常为：
```
linux-aarch64-a3-2-x51bm-runner-ksnwc
         ↑节点池  ↑物理机编号   ↑pod随机后缀
```

### 3b. 定位 Namespace

```bash
# 自动发现 runner pod 所在 namespace（不确定时使用）
kubectl get pods --all-namespaces | grep <runner_name>
```

### 3c. 查物理节点（区分两种场景）

**Pod 未销毁**：
```bash
kubectl get pod <runner_name> -n <namespace> \
  -o custom-columns=NODE:.spec.nodeName
```

**Pod 已销毁**：从完整日志中搜索调度记录：
```bash
# 先拉完整日志
gh run view --job <job_id> --log --repo <owner/repo> > full.log
grep "Successfully assigned <runner_name> to" full.log
# 或在 Loki/ELK 中搜索相同关键词
```

### 3d. 多机任务 — 优先定位 Master 节点（Rank 0）

当任务涉及多机（multi-node）且某节点报 `Timeout` 时，**不要孤立分析报错节点**，先找 Rank 0：

```bash
# 方法一：从日志中找 MASTER_ADDR 环境变量
grep "MASTER_ADDR" full.log

# 方法二：从 RANK_TABLE_FILE 中找 rank_id=0 对应的 device_ip
grep -A5 '"rank_id": "0"' <rank_table_file>
```

找到 Master 节点后，优先检查其日志：
- 是否有 `Unexpected Exit`
- 是否有 NPU 驱动报错（`ERR99999`、`error code 507035`）
- 是否有进程崩溃（exit `-9`、`Bus error`）

Master 有问题 → 从节点只是连锁超时，根因在 Master。

### 3e. 确认 NPU 健康

```bash
npu-smi info  # 在对应节点上执行
kubectl get nodes --kubeconfig=<集群kubeconfig>
```

---

## Step 4：根因分类

### 类型 A：基础设施 / 环境故障
信号：容器启动失败、网络超时、NPU 硬件报错（`ERR99999`）、OOM（`Bus error` / `Killed` / exit `-9`）、exit code 255（K8s 强制终止）、ModelScope 下载超时、多机 Timeout（见 Step 3d）

**责任方**：基础设施团队

### 类型 B：代码 Bug（PR 引入）
信号：exit code 1、Python 异常堆栈（`UnboundLocalError` / `AssertionError` / `AttributeError`）、失败与 PR diff 直接对应、重跑仍失败、UT 卡死

**责任方**：PR 作者

### 类型 C：精度回归
信号：`Accuracy of ... is X, lower than Y`、精度跌幅 > 5%

**责任方**：PR 作者（需与算法团队确认）

### 类型 D：YAML / 配置错误
信号：`undefined variable "False"`、workflow 语法报错

**责任方**：PR 作者 / CI 维护者

### 类型 E：疑难 / 概率性问题
信号：偶发挂死（如 triton ascend 概率挂）、无明确异常堆栈、重跑有时通过

**常见错误模式速查**：`references/common-patterns.md`
**vllm-ascend 专项**：`references/vllm-ascend.md`

---

## Step 5：输出报告

### 写入文件

将诊断写入 `<skill目录>/reports/diagnosis-<run_id>.md`，每个失败 Job 一节，格式如下：

```markdown
# CI 故障诊断报告

**Run**: [Workflow名称] #[Run ID]
**PR**: [仓库/PR号] ([分支名])
**时间**: [开始] ~ [结束]

---

## 故障一：[Job 名称]

- **定性**: [环境问题 / 代码Bug / 精度回归 / 配置错误 / 疑难]
- **根因**: [一句话直接原因，如"K8s 容器运行时在测试阶段强制终止，exit code 255"]
- **关键标识**: `[最关键的一行错误，如 ERR99999 / AssertionError / exit code 255]`
- **责任方**: [基础设施团队 / PR 作者]
- **建议**: [重跑 / 修改 XX 文件 XX 行 / 上报运维 / 检查 Master 节点 XX]
- **节点**: [仅硬件故障时填写：Runner Pod名 → 物理节点名，其他类型省略]

---

[其他 Job 以同样格式继续]

## 汇总

| Job | 定性 | 责任方 | 建议 |
|-----|------|--------|------|
| ... | 环境问题 | 基础设施团队 | 重跑 |
| ... | 代码Bug | PR 作者 | 修代码 |
```

**报告精简原则**：
- 不粘贴大段原始日志，只引用最关键的一行错误标识
- 不描述诊断过程（不写"我们检查了A，发现B"），直接给结论
- 节点池、物理机等环境信息仅在硬件故障时填写，其他类型省略
- 若同一 Run 中多个 Job 根因相同，可合并为一条说明

### 对话摘要

文件写完后，在对话中只输出：
1. 写入的文件路径（一句话）
2. 直接粘贴 `## 汇总` 表格

---

## Step 6：等待人工确认

输出摘要后停止，等待确认：
- "确认" / "没问题" → 进入 Step 7（仅代码问题）
- 提出修正 → 更新分析，重新写入文件（追加修订版本，不覆盖原文）
- 基础设施问题 → 提供操作建议后结束，不执行代码修改

---

## Step 7：自动修改代码（仅类型 B/C/D）

用户确认后执行代码修改：最小改动，先读文件再改，每处修改说明改了什么和为什么。修改完成后输出 diff 摘要和建议 commit message。

---

## 参考资料

- **常见错误模式速查**：`references/common-patterns.md`（网络超时/容器崩溃/UT卡死/triton挂/NPU硬件等）
- **vllm-ascend 专用**：`references/vllm-ascend.md`（Runner 类型、内部服务、workflow 触发逻辑）
- **分类判断详细逻辑**：`references/classification-guide.md`
