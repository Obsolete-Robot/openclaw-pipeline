#!/bin/bash
# request-review.sh — Lightweight webhook ping for PR review
# Works standalone. No pipeline skill needed. Just curl + jq.
#
# Usage:
#   request-review.sh <project> <issue_num> <pr_num> <thread_id>
#
# Reads webhook URL from: ~/.config/discord/projects/<project>/forum-webhook
# Reads orchestrator ID from project config or ORCHESTRATOR_ID env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT="${1:-}"
ISSUE_NUM="${2:-}"
PR_NUM="${3:-}"
THREAD_ID="${4:-}"

if [ -z "$PROJECT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$PR_NUM" ] || [ -z "$THREAD_ID" ]; then
  echo "Usage: request-review.sh <project> <issue_num> <pr_num> <thread_id>"
  echo ""
  echo "Example: request-review.sh tac 42 87 1234567890"
  exit 1
fi

# Load webhook URL
WEBHOOK_FILE="$HOME/.config/discord/projects/${PROJECT}/forum-webhook"
if [ ! -f "$WEBHOOK_FILE" ]; then
  echo "❌ Webhook file not found: $WEBHOOK_FILE"
  exit 1
fi
WEBHOOK_URL="$(cat "$WEBHOOK_FILE")"

# Load orchestrator ID from config chain
ORCHESTRATOR_ID="${ORCHESTRATOR_ID:-}"
if [ -z "$ORCHESTRATOR_ID" ]; then
  # Try pipeline configs
  [ -f "$SCRIPT_DIR/pipeline.conf" ] && source "$SCRIPT_DIR/pipeline.conf"
  [ -f "$SCRIPT_DIR/pipeline.local.conf" ] && source "$SCRIPT_DIR/pipeline.local.conf"
  # Try project config
  local_conf="$SCRIPT_DIR/../projects/${PROJECT}.conf"
  [ -f "$local_conf" ] && source "$local_conf"
fi

if [ -z "$ORCHESTRATOR_ID" ]; then
  echo "❌ ORCHESTRATOR_ID not set. Set it via env var or in pipeline config."
  exit 1
fi

# Load repo info for context (optional, best-effort)
REPO="${REPO:-unknown}"
if [ -z "${REPO:-}" ] || [ "$REPO" = "unknown" ]; then
  local_conf="$SCRIPT_DIR/../projects/${PROJECT}.conf"
  [ -f "$local_conf" ] && REPO=$(grep '^REPO=' "$local_conf" | head -1 | cut -d'"' -f2)
fi

PR_URL="https://github.com/${REPO}/pull/${PR_NUM}"
ISSUE_URL="https://github.com/${REPO}/issues/${ISSUE_NUM}"

# Post review request via webhook (@mention orchestrator)
PIPELINE_CMD="~/.openclaw/workspace/skills/pipeline/scripts/pipeline.sh -p ${PROJECT}"

MSG="<@${ORCHESTRATOR_ID}> 📤 **Review requested: PR #${PR_NUM}**

🔗 PR: ${PR_URL}
📋 Issue: ${ISSUE_URL}
📦 Repo: \`${REPO}\`

**Instructions:**
1. \`gh pr diff ${PR_NUM} --repo ${REPO}\` — read the diff
2. \`cd <repo> && cat .github/PIPELINE.md\` — read project review criteria & gotchas
3. Review for: correctness, edge cases, error handling, security, coding standards
4. Post review to GitHub:
   ✅ \`gh pr review ${PR_NUM} --repo ${REPO} --approve --body 'summary'\`
   ❌ \`gh pr review ${PR_NUM} --repo ${REPO} --request-changes --body 'feedback'\`
5. **Post your result back to this thread via webhook, tagging the orchestrator:**
   \`\`\`
   WH=\$(cat ~/.config/discord/projects/${PROJECT}/forum-webhook)
   curl -s -X POST \"\${WH}?thread_id=${THREAD_ID}\" -H 'Content-Type: application/json' -d '{\"content\":\"<@${ORCHESTRATOR_ID}> ✅ PR #${PR_NUM} APPROVED — summary here\",\"username\":\"Pipeline\"}'
   \`\`\`
   Or if pipeline CLI available:
   ✅ \`${PIPELINE_CMD} approve ${ISSUE_NUM}\`
   ❌ \`${PIPELINE_CMD} reject ${ISSUE_NUM} 'feedback'\`"

HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null -X POST \
  "${WEBHOOK_URL}?thread_id=${THREAD_ID}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg content "$MSG" --arg username "Pipeline" \
    '{content: $content, username: $username}')")

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "✅ Review requested for PR #${PR_NUM} — orchestrator pinged in thread"
else
  echo "❌ Webhook failed (HTTP $HTTP_CODE)"
  exit 1
fi
