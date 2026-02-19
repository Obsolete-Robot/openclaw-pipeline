#!/bin/bash
# ============================================
# pipeline - Dumb orchestrator for issue→PR workflow
# ============================================
# Multi-project, multi-guild state machine that routes work
# between OpenClaw sessions without burning LLM tokens.
#
# Each task gets a FRESH isolated session via `openclaw agent`.
# No context accumulation. No role confusion.
#
# Usage:
#   pipeline -p <project> new "bug: panel doesn't resize"
#   pipeline -p <project> assign <issue_num>
#   pipeline -p <project> pr-ready <issue_num> --pr <pr_num>
#   pipeline -p <project> approve <issue_num>
#   pipeline -p <project> reject <issue_num> "reason"
#   pipeline -p <project> status [issue_num]
#   pipeline -p <project> list
#   pipeline projects
#   pipeline init <name>
#   pipeline setup <name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="$SKILL_DIR/projects"

# ============ PROJECT LOADING ============

load_project() {
  local name="$1"
  local conf="$PROJECTS_DIR/${name}.conf"
  
  if [ ! -f "$conf" ]; then
    echo "❌ Project '$name' not found at $conf"
    echo "Available projects:"
    list_projects
    echo ""
    echo "Create one with: pipeline init <name>"
    exit 1
  fi
  
  source "$SCRIPT_DIR/pipeline.conf"  # global defaults
  [ -f "$SCRIPT_DIR/pipeline.local.conf" ] && source "$SCRIPT_DIR/pipeline.local.conf"  # local overrides
  source "$conf"                      # project overrides
  
  STATE_FILE="$PROJECTS_DIR/${name}.state.json"
  [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
  
  PROJECT_NAME="$name"
}

list_projects() {
  if [ ! -d "$PROJECTS_DIR" ] || [ -z "$(ls "$PROJECTS_DIR"/*.conf 2>/dev/null)" ]; then
    echo "  (none — run: pipeline init <name>)"
    return
  fi
  for f in "$PROJECTS_DIR"/*.conf; do
    local name=$(basename "$f" .conf)
    [ "$name" = "example" ] && continue
    local repo=$(grep '^REPO=' "$f" | head -1 | cut -d'"' -f2)
    local guild=$(grep '^GUILD_ID=' "$f" | head -1 | cut -d'"' -f2)
    echo "  $name  →  $repo  (guild: $guild)"
  done
}

# ============ HELPERS ============

load_secrets() {
  export DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-$(cat "$BOT_TOKEN_FILE" 2>/dev/null)}"
  FORUM_WEBHOOK_URL="${FORUM_WEBHOOK_URL:-$(cat "$FORUM_WEBHOOK_FILE" 2>/dev/null)}"
  REVIEWS_WEBHOOK_URL="${REVIEWS_WEBHOOK_URL:-$(cat "$REVIEWS_WEBHOOK_FILE" 2>/dev/null)}"
  PRODUCTION_WEBHOOK_URL="${PRODUCTION_WEBHOOK_URL:-$(cat "$PRODUCTION_WEBHOOK_FILE" 2>/dev/null || echo "")}"
}

get_issue() {
  local num="$1" field="$2"
  jq -r ".\"$num\".$field // empty" "$STATE_FILE"
}

set_issue() {
  local num="$1"; shift
  local tmp=$(mktemp)
  local content=$(cat "$STATE_FILE")
  
  # Build JSON object with all key=value pairs
  local updates="{}"
  while [ $# -gt 0 ]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    updates=$(echo "$updates" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
    shift
  done
  
  # Merge updates into the issue entry
  echo "$content" | jq --arg num "$num" --argjson updates "$updates" \
    '.[$num] //= {} | .[$num] += $updates' > "$tmp" && mv "$tmp" "$STATE_FILE"
}

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

webhook_post() {
  local url="$1" msg="$2" sender="${3:-Pipeline}" thread_id="${4:-}"
  local endpoint="$url"
  [ -n "$thread_id" ] && endpoint="${url}?thread_id=${thread_id}"
  
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$endpoint" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg content "$msg" --arg username "$sender" \
      '{content: $content, username: $username}')")
  
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    return 0
  else
    echo "❌ Webhook failed (HTTP $http_code)" >&2
    return 1
  fi
}

# Post as Larry bot (won't trigger self-response)
# Use for status updates, results — anything Larry shouldn't react to
bot_post() {
  local channel_id="$1" msg="$2"
  
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o /dev/null -X POST \
    "https://discord.com/api/v10/channels/${channel_id}/messages" \
    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg content "$msg" '{content: $content}')")
  
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    return 0
  else
    echo "❌ Bot post failed (HTTP $http_code)" >&2
    return 1
  fi
}

create_forum_thread() {
  local title="$1" content="$2" tag_id="${3:-}"
  local args=("$FORUM_CHANNEL" --name "$title" --content "$content")
  [ -n "$tag_id" ] && args+=(--tag "$tag_id")
  
  local result
  result=$(node "$SCRIPTS_DIR/create-post.mjs" "${args[@]}" 2>&1)
  echo "$result" | grep "Thread ID:" | awk '{print $3}'
}

archive_thread() {
  local thread_id="$1"
  curl -s -o /dev/null -X PATCH \
    "https://discord.com/api/v10/channels/$thread_id" \
    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"archived": true}'
}

# Spawn a fresh OpenClaw session for a task.
# Usage: spawn_session <session_id> <message> [--deliver-to <thread_id>]
# Returns the agent's response on stdout.
spawn_session() {
  local session_id="$1"
  local message="$2"
  local deliver_thread="${3:-}"
  
  local args=(
    agent
    --session-id "$session_id"
    --message "$message"
    --thinking "${AGENT_THINKING:-low}"
    --timeout "${AGENT_TIMEOUT:-600}"
  )
  
  # Optionally deliver reply to a Discord thread
  if [ -n "$deliver_thread" ]; then
    args+=(--deliver --reply-channel discord --reply-to "$deliver_thread")
  fi
  
  openclaw "${args[@]}" 2>/dev/null
}

# ============ COMMANDS ============

cmd_new() {
  local description=""
  local auto_merge="${DEFAULT_AUTO_MERGE:-true}"
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-auto-merge) auto_merge="false"; shift ;;
      --auto-merge) auto_merge="true"; shift ;;
      *) description="$1"; shift ;;
    esac
  done
  
  if [ -z "$description" ]; then
    echo "Usage: pipeline -p $PROJECT_NAME new \"bug: short description\" [--no-auto-merge]"
    exit 1
  fi
  
  load_secrets
  
  # Determine type from prefix
  local issue_type="task"
  local clean_desc="$description"
  if [[ "$description" =~ ^bug:\ *(.*) ]]; then
    issue_type="bug"; clean_desc="${BASH_REMATCH[1]}"
  elif [[ "$description" =~ ^feature:\ *(.*) ]]; then
    issue_type="feature"; clean_desc="${BASH_REMATCH[1]}"
  elif [[ "$description" =~ ^task:\ *(.*) ]]; then
    issue_type="task"; clean_desc="${BASH_REMATCH[1]}"
  fi
  
  local label=""
  case "$issue_type" in
    bug) label="bug" ;;
    feature) label="enhancement" ;;
  esac
  
  # Generate issue spec via fresh LLM session
  local title="" body=""
  
  if [ "${USE_LLM:-true}" = "true" ] && command -v openclaw &>/dev/null; then
    echo "🧠 Spawning LLM session for issue spec..."
    
    local session_id="pipeline-spec-$(date +%s)"
    local prompt="You are a technical writer. Write a GitHub issue for the following ${issue_type}.

Return ONLY the issue content in this EXACT format — no commentary, no markdown fences:

TITLE: <concise issue title>
---
<issue body in markdown>

For bugs include: Description, Steps to Reproduce, Expected Behavior, Actual Behavior, Acceptance Criteria.
For features/tasks include: Description, Requirements, Acceptance Criteria.

${issue_type}: ${clean_desc}
Repository: ${REPO}"

    local response
    response=$(spawn_session "$session_id" "$prompt") || true
    
    if [ -n "$response" ]; then
      title=$(echo "$response" | sed -n 's/^TITLE: *//p' | head -1)
      body=$(echo "$response" | sed '1,/^---$/d')
    fi
  fi
  
  # Fallback template
  if [ -z "$title" ]; then
    echo "📝 Using template (LLM unavailable)..."
    title="$(echo "$clean_desc" | sed 's/^\(.\)/\U\1/')"
    case "$issue_type" in
      bug)
        body="## Description
${clean_desc}

## Steps to Reproduce
1. <!-- describe steps -->

## Expected Behavior
<!-- what should happen -->

## Actual Behavior
<!-- what happens instead -->

## Acceptance Criteria
- [ ] Bug is fixed
- [ ] No regressions introduced" ;;
      *)
        body="## Description
${clean_desc}

## Acceptance Criteria
- [ ] Implementation complete
- [ ] Tests passing" ;;
    esac
  fi
  
  echo "📋 Creating GitHub issue: $title"
  
  local gh_args=(issue create --repo "$REPO" --title "$title" --body "$body")
  [ -n "$label" ] && gh_args+=(--label "$label")
  
  local issue_url
  issue_url=$(gh "${gh_args[@]}" 2>&1)
  local issue_num
  issue_num=$(echo "$issue_url" | grep -oP '/issues/\K\d+' | tail -1)
  
  if [ -z "$issue_num" ]; then
    echo "❌ Failed to create issue"
    echo "$issue_url"
    exit 1
  fi
  
  echo "✅ Issue #$issue_num created: $issue_url"
  
  # Forum tag
  local tag_id=""
  case "$issue_type" in
    bug) tag_id="$TAG_BUG" ;;
    feature) tag_id="$TAG_FEATURE" ;;
    *) tag_id="${TAG_TASK:-}" ;;
  esac
  
  # Create forum thread
  local thread_title="#${issue_num}: ${title}"
  [ ${#thread_title} -gt 100 ] && thread_title="${thread_title:0:97}..."
  
  echo "🧵 Creating forum thread..."
  local thread_id
  thread_id=$(create_forum_thread "$thread_title" "Tracking issue #${issue_num} | Project: ${PROJECT_NAME}" "$tag_id")
  
  if [ -z "$thread_id" ]; then
    echo "❌ Failed to create forum thread"
    exit 1
  fi
  
  echo "✅ Thread created: $thread_id"
  
  set_issue "$issue_num" \
    "state=created" \
    "title=$title" \
    "type=$issue_type" \
    "thread=$thread_id" \
    "url=$issue_url" \
    "branch=issue-${issue_num}" \
    "project=$PROJECT_NAME" \
    "auto_merge=$auto_merge" \
    "created=$(timestamp)"
  
  echo ""
  echo "📌 Issue #$issue_num tracked"
  echo "🎯 Thread: https://discord.com/channels/$GUILD_ID/$thread_id"
  
  # Post issue summary to thread (wait for manual assign)
  local thread_msg="📋 **Issue #${issue_num}: ${title}**
${issue_url}

${body}

---
**To assign:** \`pipeline -p ${PROJECT_NAME} assign ${issue_num}\`"

  webhook_post "$FORUM_WEBHOOK_URL" "$thread_msg" "Pipeline" "$thread_id"
  
  echo ""
  echo "Ready for assignment: pipeline -p $PROJECT_NAME assign $issue_num"
}

# Post issue details to thread via webhook, @mention Larry to pick it up.
# No hidden sessions — Larry works in the thread, visible and interactive.
_assign_to_thread() {
  local issue_num="$1" title="$2" url="$3" body="$4" thread="$5"
  local branch="issue-${issue_num}"
  
  # Extract first paragraph as description (up to first blank line or ## heading)
  local description
  description=$(echo "$body" | sed '/^$/q; /^##/q' | head -5 | sed '/^$/d; /^##/d')
  [ -z "$description" ] && description="See issue for details."
  
  local pipeline_cmd="~/.openclaw/workspace/skills/pipeline/scripts/pipeline.sh -p ${PROJECT_NAME}"
  
  local assign_msg="<@$LARRY_BOT_ID> **Issue #${issue_num}: ${title}**
${url}

${description}

---
⚠️ **RULES — you MUST follow this process:**
1. Do the work yourself here. No sub-agents or branch workers.
2. Branch: \`${branch}\` → PR to \`${MERGE_TARGET:-dev}\` | Repo: \`${REPO}\`
3. After creating PR, run: \`${pipeline_cmd} pr-ready ${issue_num} --pr <N>\`
4. **WAIT for the review** to come back in this thread before proceeding.
5. After review ✅: \`${pipeline_cmd} approve ${issue_num}\`
6. After review ❌: fix the issues, push, and re-request review.
7. If already resolved/duplicate: \`${pipeline_cmd} close ${issue_num} \"reason\"\`

**🚫 Do NOT use raw \`gh pr merge\`, \`gh issue close\`, or self-review.**
**🚫 Do NOT skip the review step or merge your own PR.**
Pipeline commands handle merging, deploying, and notifying channels."

  webhook_post "$FORUM_WEBHOOK_URL" "$assign_msg" "Pipeline" "$thread"
  
  set_issue "$issue_num" \
    "state=assigned" \
    "branch=$branch" \
    "assigned=$(timestamp)"
  
  echo "✅ Issue #$issue_num posted to thread — Larry will pick it up"
}

cmd_assign() {
  local issue_num="$1"
  [ -z "$issue_num" ] && { echo "Usage: pipeline -p $PROJECT_NAME assign <issue_num>"; exit 1; }
  
  load_secrets
  
  local thread=$(get_issue "$issue_num" "thread")
  local title=$(get_issue "$issue_num" "title")
  local url=$(get_issue "$issue_num" "url")
  
  [ -z "$thread" ] && { echo "❌ Issue #$issue_num not tracked"; exit 1; }
  
  # Fetch full issue body from GitHub
  local body
  body=$(gh issue view "$issue_num" --repo "$REPO" --json body -q '.body' 2>/dev/null)
  
  # Post to thread via webhook — Larry picks it up and works in the open
  _assign_to_thread "$issue_num" "$title" "$url" "$body" "$thread"
}

cmd_pr_ready() {
  local issue_num="$1"; shift || true
  local pr_num=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr_num="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  [ -z "$issue_num" ] || [ -z "$pr_num" ] && { echo "Usage: pipeline -p $PROJECT_NAME pr-ready <issue_num> --pr <pr_num>"; exit 1; }
  
  load_secrets
  
  local thread=$(get_issue "$issue_num" "thread")
  local title=$(get_issue "$issue_num" "title")
  local auto_merge=$(get_issue "$issue_num" "auto_merge")
  [ -z "$thread" ] && { echo "❌ Issue #$issue_num not tracked"; exit 1; }
  
  local pr_url="https://github.com/${REPO}/pull/${pr_num}"
  
  # Post to #pr-reviews via webhook (informational)
  webhook_post "$REVIEWS_WEBHOOK_URL" "📤 **PR #${pr_num}** — ${title}
🔗 PR: ${pr_url}
📋 Issue: https://github.com/${REPO}/issues/${issue_num}
🧵 Thread: <#${thread}>
Review in progress..." "Larry"

  # Post review request to thread via webhook — @mention Larry to do the review
  local issue_url="https://github.com/${REPO}/issues/${issue_num}"
  webhook_post "$FORUM_WEBHOOK_URL" "<@$LARRY_BOT_ID> **PR #${pr_num} ready for review**
🔗 ${pr_url}
📋 Issue #${issue_num}: ${issue_url}

**Review this PR yourself.** Fetch the diff with \`gh pr diff ${pr_num} --repo ${REPO}\`, check correctness, edge cases, error handling, code quality.

**After reviewing, do BOTH:**
1. Post your review to GitHub: \`gh pr review ${pr_num} --repo ${REPO} --approve --body \"your review summary\"\` (or \`--request-changes\`)
2. Run the pipeline command:
   - ✅ If good: \`~/.openclaw/workspace/skills/pipeline/scripts/pipeline.sh -p ${PROJECT_NAME} approve ${issue_num}\`
   - ❌ If changes needed: \`~/.openclaw/workspace/skills/pipeline/scripts/pipeline.sh -p ${PROJECT_NAME} reject ${issue_num} \"reason\"\`

**Do NOT skip either step.** The GitHub review creates a paper trail. The pipeline command triggers merge and deploy." "Pipeline" "$thread"

  set_issue "$issue_num" \
    "state=in-review" \
    "pr=$pr_num" \
    "pr_url=$pr_url" \
    "review_requested=$(timestamp)"
  
  echo "✅ PR #$pr_num posted for review in thread"
}

cmd_approve() {
  local issue_num="$1"
  [ -z "$issue_num" ] && { echo "Usage: pipeline -p $PROJECT_NAME approve <issue_num>"; exit 1; }
  
  load_secrets
  
  local thread=$(get_issue "$issue_num" "thread")
  local pr=$(get_issue "$issue_num" "pr")
  local title=$(get_issue "$issue_num" "title")
  local url=$(get_issue "$issue_num" "url")
  local auto_merge=$(get_issue "$issue_num" "auto_merge")
  [ -z "$thread" ] && { echo "❌ Issue #$issue_num not tracked"; exit 1; }
  
  local pr_url="https://github.com/${REPO}/pull/${pr}"
  
  # Post GitHub approval
  echo "✅ Approving PR #$pr on GitHub..."
  gh pr review "$pr" --repo "$REPO" --approve --body "LGTM! ✅ Approved via pipeline review." 2>/dev/null || true
  
  # Post to #pr-reviews via webhook (informational)
  webhook_post "$REVIEWS_WEBHOOK_URL" "✅ **PR #${pr} APPROVED** — ${title}
🔗 ${pr_url} | 📋 Issue #${issue_num}
$([ "$auto_merge" = "false" ] && echo "⏳ Manual merge required." || echo "🔀 Auto-merging to \`${MERGE_TARGET:-dev}\`...")" "Larry"
  
  if [ "$auto_merge" = "false" ]; then
    webhook_post "$FORUM_WEBHOOK_URL" "<@$LARRY_BOT_ID> ✅ **PR #${pr} APPROVED**

Review passed! Manual merge requested.
When ready: \`gh pr merge ${pr} --repo ${REPO} --squash\`" "Pipeline" "$thread"
    
    set_issue "$issue_num" "state=approved" "approved=$(timestamp)"
    echo "✅ PR #$pr approved (manual merge required)"
    return
  fi
  
  echo "🔀 Merging PR #$pr to ${MERGE_TARGET:-dev}..."
  if gh pr merge "$pr" --repo "$REPO" --squash --delete-branch 2>/dev/null; then
    echo "✅ PR #$pr merged"
    
    # Close the issue
    gh issue close "$issue_num" --repo "$REPO" --reason completed 2>/dev/null || true
    
    # Post as Larry (no response needed)
    webhook_post "$FORUM_WEBHOOK_URL" "🎉 **Issue #${issue_num} RESOLVED**

PR #${pr} merged to \`${MERGE_TARGET:-dev}\`
Thread will be archived." "Pipeline" "$thread"
    
    # Archive thread and apply resolved tag
    sleep 2  # Give time for the message to post
    archive_thread "$thread"
    
    if [ -n "${TAG_RESOLVED:-}" ]; then
      curl -s -o /dev/null -X PATCH \
        "https://discord.com/api/v10/channels/$thread" \
        -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"applied_tags\": [\"$TAG_RESOLVED\"]}"
    fi
    
    # Deploy if DEPLOY_STEPS defined
    if [ -n "${DEPLOY_STEPS:-}" ]; then
      echo "🚀 Running deploy steps..."
      if eval "$DEPLOY_STEPS" 2>&1; then
        echo "✅ Deploy successful"
        
        # Post to #production
        if [ -n "${PRODUCTION_CHANNEL:-}" ]; then
          local deploy_msg="🚀 **Deployed to dev:** #${issue_num} — ${title}
PR #${pr} merged to \`${MERGE_TARGET:-dev}\`
${pr_url}
${DEPLOY_POST_NOTES:+
📝 ${DEPLOY_POST_NOTES}}"
          webhook_post "$PRODUCTION_WEBHOOK_URL" "$deploy_msg" "Larry"
        fi
      else
        echo "⚠️  Deploy failed — posting manual instructions"
        if [ -n "${PRODUCTION_CHANNEL:-}" ]; then
          webhook_post "$PRODUCTION_WEBHOOK_URL" "⚠️ **Auto-deploy failed** for #${issue_num} — ${title}
PR #${pr} merged but deploy needs manual intervention.
\`\`\`bash
${DEPLOY_STEPS}
\`\`\`" "Larry"
        fi
      fi
    fi
    
    set_issue "$issue_num" "state=merged" "merged=$(timestamp)"
    echo "✅ Issue #$issue_num complete!"
  else
    echo "⚠️  Auto-merge failed (might need approvals or checks)"
    
    # Post as Larry (no response needed)
    webhook_post "$FORUM_WEBHOOK_URL" "<@$LARRY_BOT_ID> ⚠️ **Auto-merge failed**

PR #${pr} approved but merge failed. May need manual merge.
Try: \`gh pr merge ${pr} --repo ${REPO} --squash\`" "Pipeline" "$thread"
    
    set_issue "$issue_num" "state=approved" "approved=$(timestamp)"
  fi
}

cmd_reject() {
  local issue_num="$1"
  local reason="${2:-Changes requested}"
  [ -z "$issue_num" ] && { echo "Usage: pipeline -p $PROJECT_NAME reject <issue_num> [reason]"; exit 1; }
  
  load_secrets
  
  local thread=$(get_issue "$issue_num" "thread")
  local pr=$(get_issue "$issue_num" "pr")
  local title=$(get_issue "$issue_num" "title")
  local url=$(get_issue "$issue_num" "url")
  local branch=$(get_issue "$issue_num" "branch")
  [ -z "$thread" ] && { echo "❌ Issue #$issue_num not tracked"; exit 1; }
  
  local pr_url="https://github.com/${REPO}/pull/${pr}"
  
  # Post GitHub review requesting changes
  echo "📝 Posting review feedback to GitHub..."
  gh pr review "$pr" --repo "$REPO" --request-changes --body "$reason" 2>/dev/null || true
  
  # Post to #pr-reviews via webhook (informational)
  webhook_post "$REVIEWS_WEBHOOK_URL" "❌ **PR #${pr} CHANGES REQUESTED** — ${title}
🔗 ${pr_url} | 📋 Issue #${issue_num}
**Feedback:** ${reason}" "Larry"
  
  # Post feedback to thread via webhook — @mention Larry to fix
  webhook_post "$FORUM_WEBHOOK_URL" "<@$LARRY_BOT_ID> ❌ **PR #${pr} — Changes Requested**

**Feedback:** ${reason}

Please address the feedback and push fixes." "Pipeline" "$thread"
  
  set_issue "$issue_num" \
    "state=changes-requested" \
    "rejected=$(timestamp)" \
    "reject_reason=$reason"
  
  echo "✅ Rejection posted to thread"
}

cmd_close() {
  local issue_num="$1"
  local reason="${2:-Closed}"
  [ -z "$issue_num" ] && { echo "Usage: pipeline -p $PROJECT_NAME close <issue_num> [reason]"; exit 1; }
  
  load_secrets
  
  local thread=$(get_issue "$issue_num" "thread")
  local title=$(get_issue "$issue_num" "title")
  local url=$(get_issue "$issue_num" "url")
  
  gh issue close "$issue_num" --repo "$REPO" --reason completed 2>/dev/null || true
  
  # Post to #pr-reviews (informational)
  webhook_post "$REVIEWS_WEBHOOK_URL" "🔒 **Issue #${issue_num} closed** — ${title:-$url}
${url:+$url}
${reason}" "Larry"
  
  # Post to #production (visibility)
  if [ -n "${PRODUCTION_WEBHOOK_URL:-}" ]; then
    webhook_post "$PRODUCTION_WEBHOOK_URL" "🔒 **Issue #${issue_num} resolved** — ${title:-$url}
${url:+$url}
${reason}" "Larry"
  fi
  
  # Archive thread
  if [ -n "$thread" ]; then
    archive_thread "$thread" 2>/dev/null || true
    if [ -n "${TAG_RESOLVED:-}" ]; then
      curl -s -o /dev/null -X PATCH \
        "https://discord.com/api/v10/channels/$thread" \
        -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"applied_tags\": [\"$TAG_RESOLVED\"]}"
    fi
  fi
  
  set_issue "$issue_num" "state=closed" "closed=$(timestamp)" "close_reason=$reason"
  echo "✅ Issue #$issue_num closed"
}

cmd_status() {
  local issue_num="${1:-}"
  if [ -n "$issue_num" ]; then
    local data=$(jq -r ".\"$issue_num\" // empty" "$STATE_FILE")
    [ -z "$data" ] && { echo "❌ Issue #$issue_num not tracked"; exit 1; }
    echo "📋 [$PROJECT_NAME] Issue #$issue_num:"
    echo "$data" | jq .
  else
    echo "📋 [$PROJECT_NAME] All tracked issues:"
    jq -r 'to_entries[] | "  #\(.key) [\(.value.state)] \(.value.title // "untitled")"' "$STATE_FILE"
  fi
}

cmd_list() {
  local filter="${1:-all}"
  case "$filter" in
    open|active)
      jq -r 'to_entries[] | select(.value.state != "merged" and .value.state != "closed") | "  #\(.key) [\(.value.state)] \(.value.title)"' "$STATE_FILE" ;;
    *)
      jq -r 'to_entries[] | "  #\(.key) [\(.value.state)] \(.value.title)"' "$STATE_FILE" ;;
  esac
}

# ============ SETUP COMMANDS ============

cmd_init() {
  local name="$1"
  [ -z "$name" ] && { echo "Usage: pipeline init <project-name>"; exit 1; }
  
  local conf="$PROJECTS_DIR/${name}.conf"
  if [ -f "$conf" ]; then
    echo "❌ Project '$name' already exists at $conf"
    exit 1
  fi
  
  mkdir -p "$PROJECTS_DIR"
  
  cat > "$conf" << 'CONF'
# Project: __NAME__
# Usage: pipeline -p __NAME__ new "bug: something broke"

# ============ REQUIRED ============

REPO=""
GUILD_ID=""

# Discord channels
FORUM_CHANNEL=""
PR_REVIEW_CHANNEL=""
PRODUCTION_CHANNEL=""

# Webhook files
FORUM_WEBHOOK_FILE="$HOME/.config/discord/projects/__NAME__/forum-webhook"
REVIEWS_WEBHOOK_FILE="$HOME/.config/discord/projects/__NAME__/reviews-webhook"
PRODUCTION_WEBHOOK_FILE="$HOME/.config/discord/projects/__NAME__/production-webhook"

# GitHub token (if org needs a specific PAT)
# export GH_TOKEN="$(cat "$HOME/.config/git/github-token" 2>/dev/null)"

# ============ OPTIONAL ============

# Forum tags
TAG_BUG=""
TAG_FEATURE=""
TAG_TASK=""
TAG_RESOLVED=""

# Agent overrides
# WORKER_ID=""
# REVIEWER_ID=""

# Deploy steps (run after merge)
# DEPLOY_STEPS='cd /srv/myapp && git pull && docker-compose restart'
# DEPLOY_POST_NOTES="Remember to clear cache after deploy."
CONF

  sed -i "s/__NAME__/$name/g" "$conf"
  mkdir -p "$HOME/.config/discord/projects/$name"
  
  echo "✅ Project '$name' created at $conf"
  echo ""
  echo "Next steps:"
  echo "  1. Edit $conf — fill in REPO, GUILD_ID, channel IDs"
  echo "  2. Create webhooks and save URLs to the webhook files"
  echo "  3. Run: pipeline setup $name"
}

cmd_setup() {
  local name="$1"
  [ -z "$name" ] && { echo "Usage: pipeline setup <project-name>"; exit 1; }
  
  load_project "$name"
  
  echo "🔍 Validating project '$name'..."
  echo ""
  
  local errors=0
  
  if [ -z "$REPO" ]; then
    echo "❌ REPO not set"; ((errors++))
  else
    if gh repo view "$REPO" --json name -q '.name' &>/dev/null; then
      echo "✅ Repo: $REPO"
    else
      echo "❌ Can't access repo: $REPO"; ((errors++))
    fi
  fi
  
  [ -z "$GUILD_ID" ] && { echo "❌ GUILD_ID not set"; ((errors++)); } || echo "✅ Guild ID: $GUILD_ID"
  
  for ch in FORUM_CHANNEL PR_REVIEW_CHANNEL; do
    local val="${!ch:-}"
    [ -z "$val" ] && { echo "❌ $ch not set"; ((errors++)); } || echo "✅ $ch: $val"
  done
  
  source "$SCRIPT_DIR/pipeline.conf"
  
  [ -f "$BOT_TOKEN_FILE" ] && echo "✅ Bot token: $BOT_TOKEN_FILE" || { echo "❌ Bot token missing: $BOT_TOKEN_FILE"; ((errors++)); }
  
  for wh in FORUM_WEBHOOK_FILE REVIEWS_WEBHOOK_FILE; do
    local val="${!wh:-}"
    [ -f "$val" ] && echo "✅ $wh exists" || { echo "❌ $wh missing: $val"; ((errors++)); }
  done
  
  command -v openclaw &>/dev/null && echo "✅ openclaw CLI available" || { echo "❌ openclaw CLI not found"; ((errors++)); }
  
  echo ""
  if [ $errors -eq 0 ]; then
    echo "✅ Project '$name' is ready!"
    echo "Try: pipeline -p $name new \"bug: test issue\""
  else
    echo "❌ $errors issue(s) found. Fix and re-run setup."
  fi
}

cmd_projects() {
  echo "📦 Projects:"
  list_projects
}

# Set a config value in a project's .conf file
# Usage: pipeline config <project> <KEY> <value>
cmd_config() {
  local name="$1" key="$2" value="$3"
  
  [ -z "$name" ] || [ -z "$key" ] && { echo "Usage: pipeline config <project> <KEY> <value>"; exit 1; }
  
  local conf="$PROJECTS_DIR/${name}.conf"
  [ ! -f "$conf" ] && { echo "❌ Project '$name' not found. Run: pipeline init $name"; exit 1; }
  
  # If key already exists, replace it. Otherwise append it.
  if grep -q "^${key}=" "$conf"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$conf"
    echo "✅ Updated $key in $name"
  else
    echo "${key}=\"${value}\"" >> "$conf"
    echo "✅ Added $key to $name"
  fi
}

# Show current config for a project
cmd_config_show() {
  local name="$1"
  [ -z "$name" ] && { echo "Usage: pipeline config-show <project>"; exit 1; }
  
  local conf="$PROJECTS_DIR/${name}.conf"
  [ ! -f "$conf" ] && { echo "❌ Project '$name' not found"; exit 1; }
  
  echo "📋 Config for '$name':"
  grep -E '^[A-Z_]+=' "$conf" | while read -r line; do
    local k="${line%%=*}"
    local v="${line#*=}"
    # Mask webhook URLs
    if [[ "$k" == *WEBHOOK* ]] && [[ "$v" == *"FILE"* ]]; then
      local expanded=$(eval echo "$v" 2>/dev/null | tr -d '"')
      if [ -f "$expanded" ]; then
        echo "  $k = (file exists ✅)"
      else
        echo "  $k = (file missing ❌)"
      fi
    else
      echo "  $k = $v"
    fi
  done
}

# Create webhooks for a project's channels
# Usage: pipeline create-webhooks <project>
cmd_create_webhooks() {
  local name="$1"
  [ -z "$name" ] && { echo "Usage: pipeline create-webhooks <project>"; exit 1; }
  
  local conf="$PROJECTS_DIR/${name}.conf"
  [ ! -f "$conf" ] && { echo "❌ Project '$name' not found"; exit 1; }
  
  source "$SCRIPT_DIR/pipeline.conf"
  source "$conf"
  
  local bot_token
  bot_token=$(cat "$BOT_TOKEN_FILE" 2>/dev/null)
  [ -z "$bot_token" ] && { echo "❌ Bot token not found at $BOT_TOKEN_FILE"; exit 1; }
  
  mkdir -p "$HOME/.config/discord/projects/$name"
  
  local channels=()
  local labels=()
  local webhook_vars=()
  
  if [ -n "$FORUM_CHANNEL" ]; then
    channels+=("$FORUM_CHANNEL"); labels+=("forum"); webhook_vars+=("FORUM_WEBHOOK_FILE")
  fi
  if [ -n "$PR_REVIEW_CHANNEL" ]; then
    channels+=("$PR_REVIEW_CHANNEL"); labels+=("reviews"); webhook_vars+=("REVIEWS_WEBHOOK_FILE")
  fi
  if [ -n "$PRODUCTION_CHANNEL" ]; then
    channels+=("$PRODUCTION_CHANNEL"); labels+=("production"); webhook_vars+=("PRODUCTION_WEBHOOK_FILE")
  fi
  
  for i in "${!channels[@]}"; do
    local ch="${channels[$i]}"
    local label="${labels[$i]}"
    local wh_var="${webhook_vars[$i]}"
    local wh_file="$HOME/.config/discord/projects/$name/${label}-webhook"
    
    # Skip if webhook already exists
    if [ -f "$wh_file" ]; then
      echo "⏭️  $label webhook already exists, skipping"
      continue
    fi
    
    local result
    result=$(curl -s -X POST "https://discord.com/api/v10/channels/${ch}/webhooks" \
      -H "Authorization: Bot $bot_token" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"Pipeline ($label)\"}")
    
    local wh_id=$(echo "$result" | jq -r '.id // empty')
    local wh_token=$(echo "$result" | jq -r '.token // empty')
    
    if [ -n "$wh_id" ] && [ -n "$wh_token" ]; then
      echo "https://discord.com/api/webhooks/${wh_id}/${wh_token}" > "$wh_file"
      echo "✅ Created $label webhook: $wh_id"
    else
      local err=$(echo "$result" | jq -r '.message // "unknown error"')
      echo "❌ Failed to create $label webhook: $err"
    fi
  done
}

# Fetch and set forum tags for a project
# Usage: pipeline fetch-tags <project>
cmd_fetch_tags() {
  local name="$1"
  [ -z "$name" ] && { echo "Usage: pipeline fetch-tags <project>"; exit 1; }
  
  local conf="$PROJECTS_DIR/${name}.conf"
  [ ! -f "$conf" ] && { echo "❌ Project '$name' not found"; exit 1; }
  
  source "$SCRIPT_DIR/pipeline.conf"
  source "$conf"
  
  [ -z "$FORUM_CHANNEL" ] && { echo "❌ FORUM_CHANNEL not set"; exit 1; }
  
  local bot_token
  bot_token=$(cat "$BOT_TOKEN_FILE" 2>/dev/null)
  [ -z "$bot_token" ] && { echo "❌ Bot token not found"; exit 1; }
  
  local result
  result=$(curl -s "https://discord.com/api/v10/channels/$FORUM_CHANNEL" \
    -H "Authorization: Bot $bot_token")
  
  local tags
  tags=$(echo "$result" | jq -r '.available_tags // []')
  
  if [ "$tags" = "[]" ] || [ "$tags" = "null" ]; then
    echo "ℹ️  No forum tags found on channel $FORUM_CHANNEL"
    return
  fi
  
  echo "📋 Forum tags found:"
  echo "$tags" | jq -r '.[] | "  \(.id) → \(.name)"'
  
  # Auto-map common tag names
  echo "$tags" | jq -r '.[] | "\(.id) \(.name)"' | while read -r tag_id tag_name; do
    local lower=$(echo "$tag_name" | tr '[:upper:]' '[:lower:]')
    if echo "$lower" | grep -q "bug"; then
      cmd_config "$name" "TAG_BUG" "$tag_id"
    elif echo "$lower" | grep -q "feature\|enhancement"; then
      cmd_config "$name" "TAG_FEATURE" "$tag_id"
    elif echo "$lower" | grep -q "question"; then
      cmd_config "$name" "TAG_QUESTION" "$tag_id"
    elif echo "$lower" | grep -q "resolved\|done\|complete"; then
      cmd_config "$name" "TAG_RESOLVED" "$tag_id"
    elif echo "$lower" | grep -q "task"; then
      cmd_config "$name" "TAG_TASK" "$tag_id"
    fi
  done
}

# ============ MAIN ============

PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project) PROJECT="$2"; shift 2 ;;
    *) break ;;
  esac
done

CMD="${1:-help}"
shift || true

case "$CMD" in
  projects)       cmd_projects; exit 0 ;;
  init)           cmd_init "$@"; exit 0 ;;
  config)          cmd_config "$@"; exit 0 ;;
  config-show)     cmd_config_show "$@"; exit 0 ;;
  create-webhooks) cmd_create_webhooks "$@"; exit 0 ;;
  fetch-tags)      cmd_fetch_tags "$@"; exit 0 ;;
  setup)           cmd_setup "${PROJECT:-$1}"; exit 0 ;;
  help|--help|-h)
    echo "pipeline - Multi-project issue→PR orchestrator"
    echo ""
    echo "Each task spawns a FRESH session — no context accumulation."
    echo ""
    echo "Project management:"
    echo "  pipeline projects                         List all projects"
    echo "  pipeline init <name>                      Create new project config"
    echo "  pipeline setup <name>                     Validate project setup"
    echo "  pipeline config <name> <KEY> <value>      Set a project config value"
    echo "  pipeline config-show <name>               Show project config"
    echo "  pipeline create-webhooks <name>           Auto-create Discord webhooks"
    echo "  pipeline fetch-tags <name>                Auto-detect forum tags"
    echo ""
    echo "Workflow (requires -p <project>):"
    echo "  pipeline -p <proj> new \"type: desc\"       Create issue + thread"
    echo "  pipeline -p <proj> assign <num>           Spawn worker session"
    echo "  pipeline -p <proj> pr-ready <n> --pr <pr> Spawn reviewer session"
    echo "  pipeline -p <proj> approve <num>          Merge + close + archive"
    echo "  pipeline -p <proj> reject <num> [why]     Spawn fix session"
    echo "  pipeline -p <proj> close <num>            Manual close"
    echo "  pipeline -p <proj> status [num]           Show issue state"
    echo "  pipeline -p <proj> list [open|all]        List issues"
    echo ""
    echo "Types: bug:, feature:, task: (prefix in description)"
    echo ""
    echo "Flow:"
    echo "  new      → creates GitHub issue + Discord forum thread"
    echo "  assign   → posts issue to thread via webhook (@mentions agent)"
    echo "  pr-ready → posts review request to thread + #pr-reviews"
    echo "  approve  → merges PR, deploys, posts to #production"
    echo "  reject   → posts feedback to thread (@mentions agent)"
    echo "  close    → closes issue, notifies channels, archives thread"
    exit 0
    ;;
esac

# Fall back to default project from config
if [ -z "$PROJECT" ]; then
  source "$SCRIPT_DIR/pipeline.conf"
  [ -f "$SCRIPT_DIR/pipeline.local.conf" ] && source "$SCRIPT_DIR/pipeline.local.conf"
  PROJECT="${DEFAULT_PROJECT:-}"
fi

if [ -z "$PROJECT" ]; then
  echo "❌ No project specified. Use: pipeline -p <project> $CMD ..."
  echo ""
  echo "Available projects:"
  list_projects
  exit 1
fi

load_project "$PROJECT"

case "$CMD" in
  new)        cmd_new "$*" ;;
  assign)     cmd_assign "$@" ;;
  pr-ready)   cmd_pr_ready "$@" ;;
  approve)    cmd_approve "$@" ;;
  reject)     cmd_reject "$@" ;;
  close)      cmd_close "$@" ;;
  status)     cmd_status "$@" ;;
  list)       cmd_list "$@" ;;
  *)
    echo "Unknown command: $CMD"
    echo "Run: pipeline help"
    exit 1
    ;;
esac
