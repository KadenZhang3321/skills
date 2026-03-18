#!/usr/bin/env bash
# scripts/fetch-run.sh  <run_id> [owner/repo]
#
# 用途：一次性抓取 CI Run 所有失败 Job 的 runner 信息和关键日志
#       将每个 Job 原始日志（可达数百行）压缩至 ~20 行关键错误行
#       在 LLM 进行 Step 2+ 推理之前完成所有数据收集，节省 token
#
# 用法：bash scripts/fetch-run.sh 22935910341
#       bash scripts/fetch-run.sh 22935910341 opensourceways/om-webserver
#
# 输出：
#   - Run 概览（Job 状态列表 + Annotations）
#   - 每个失败 Job：runner 名称 + 预过滤的关键日志（~20 行）
#   - cancelled Job：提示去看 Annotations（queue 抢占等无需读日志）
#
# 依赖：gh CLI（已登录）

set -uo pipefail

RUN_ID=${1:?"用法: fetch-run.sh <run_id> [owner/repo]"}
REPO=${2:-vllm-project/vllm-ascend}

SEP="════════════════════════════════════════════"

# ── 1. Run 概览（Job 列表 + Annotations）────────────────────────────────────
echo "$SEP"
echo " Run $RUN_ID | $REPO"
echo "$SEP"
gh run view "$RUN_ID" --repo "$REPO"
echo ""

# ── 2. 获取失败 / 取消的 Job ID ──────────────────────────────────────────────
FAILED_IDS=$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" \
  --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled") | .id')

if [[ -z "$FAILED_IDS" ]]; then
  echo "（未发现失败或取消的 Job）"
  exit 0
fi

TOTAL=$(echo "$FAILED_IDS" | wc -l | tr -d ' ')
echo "$SEP"
echo " 失败 / 取消 Job 详情（共 ${TOTAL} 个）"
echo "$SEP"

# ── 3. 逐 Job 输出 runner 信息 + 关键日志 ────────────────────────────────────
for JOB_ID in $FAILED_IDS; do
  echo ""

  # Runner 信息（一次 API 调用，获取名称 / 结论 / 时间）
  gh api "repos/$REPO/actions/jobs/$JOB_ID" \
    --jq '"── [\(.conclusion | ascii_upcase)] \(.name)\n   Runner : \(.runner_name // "(unknown)")\n   时间   : \(.started_at // "?") ~ \(.completed_at // "?")"'

  CONCLUSION=$(gh api "repos/$REPO/actions/jobs/$JOB_ID" --jq '.conclusion')

  if [[ "$CONCLUSION" == "failure" ]]; then
    echo "   关键日志 ↓"
    gh run view --job "$JOB_ID" --log-failed --repo "$REPO" 2>&1 \
      | grep -v -E '##\[group\]|##\[endgroup\]|Counting objects|remote:[[:space:]]|git config|hint:|extraheader|ssh-strict|lfs' \
      | grep -iE 'error|traceback|exception|assert|failed|killed|timeout|exit code [^0]|no such file|cannot connect|not found|oom|bus error|segfault' \
      | grep -v -E 'git |github\.com|UserWarning|ops_error\.h|error_check\.h' \
      | head -25 \
      || echo "   （--log-failed 无输出，请见 Run 概览中的 ANNOTATIONS）"
  else
    echo "   （cancelled — 根因见 Run 概览中的 ANNOTATIONS，通常为 queue 抢占）"
  fi
done

echo ""
echo "$SEP"
echo " 补充命令（按需使用）："
echo "   完整日志 : gh run view --job <id> --log --repo $REPO"
echo "   PR diff  : gh pr diff <pr> --repo $REPO --name-only"
echo "   kubectl  : kubectl get pods --all-namespaces | grep <runner_name>"
echo "$SEP"
