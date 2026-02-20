---
name: pipeline
description: >
  Issue-to-PR pipeline orchestrator. Use when the user wants to create issues, assign work,
  review PRs, or manage a development workflow. Triggers on "pipeline", "/issue", "new issue", "new bug",
  "log a bug", "log an issue", "assign issue", "pr ready", "approve pr", "reject pr",
  "pipeline status", "pipeline setup", "pipeline init". Also handles /pipeline slash command.
user-invocable: true
---

# Pipeline — Issue→PR Orchestrator

State machine for the full issue→PR lifecycle. Work happens in Discord forum threads — visible, interactive, and directly accessible to humans.

Script: `{baseDir}/scripts/pipeline.sh`
Projects: `{baseDir}/projects/<name>.conf`

## How It Works

The pipeline is a **notification router**, not a session manager. It posts @mentions via webhook to Discord threads, and the agent session listening in those threads picks up the work.

| Step | What happens |
|------|-------------|
| `new` | Creates GitHub issue + Discord forum thread |
| `assign` | Posts issue details + repo context pointers to thread via webhook (@mentions worker) |
| `pr-ready` | @mentions orchestrator in thread for review (or spawns review session as fallback) |
| `approve` | Merges PR, deploys, posts to #production, archives thread |
| `reject` | Posts feedback to thread (@mentions worker to fix) |
| `close` | Closes issue, notifies #pr-reviews + #production, archives thread |

**Key principle:** The agent works directly in the thread. No hidden sessions, no spawned workers. Humans can follow along and intervene at any point.

## Worker Onboarding Context

Worker bots are pointed at **repo-level context files** when assigned an issue:

- `.github/PIPELINE.md` — project overview, coding standards, deploy process, gotchas
- `CLAUDE.md` / `AGENTS.md` — AI-specific coding guidelines
- `CONTRIBUTING.md` — contribution conventions

A template for `.github/PIPELINE.md` is at `{baseDir}/templates/PIPELINE.md`. Copy it to your repo and customize it. This ensures any worker bot — even one with no prior knowledge of the project — knows the rules.

## Orchestrator-Routed PR Review

When `ORCHESTRATOR_ID` is set in config, `pr-ready` @mentions the orchestrator bot in the thread instead of spawning a review session directly. This means:

- **Worker bots don't need the review skill** — they just call `pr-ready`
- **The orchestrator runs the review** (via pr-review skill or sub-agent)
- **Everything happens in-thread** — visible and auditable
- **Fallback:** If `ORCHESTRATOR_ID` is not set, falls back to spawning a review session directly (legacy behavior)

## Handling Review Requests (Orchestrator Behavior)

If you are @mentioned in a pipeline forum thread with a message containing **"review PR #"** or **"Review requested: PR #"** (typically from a webhook named "Pipeline"):

1. **Extract** the PR number, issue number, and repo from the message.
2. **Clone or fetch the repo** and read `.github/PIPELINE.md` — it contains the full reviewer playbook including project-specific review criteria.
3. **Follow the reviewer instructions** in that file (fetch diff, review, post to GitHub, run pipeline approve/reject).
4. If `.github/PIPELINE.md` doesn't exist, review the PR using general best practices and post your findings in the thread.

This is agent-agnostic: any bot with repo access and this skill can be the orchestrator. The repo's `.github/PIPELINE.md` is the single source of truth for how to review.

## Slash Command Parsing

`/pipeline <command> [project] [args...]`

Map user input to shell commands:

| User says | Run |
|-----------|-----|
| `/pipeline projects` | `pipeline projects` |
| `/pipeline init myapp` | `pipeline init myapp` |
| `/pipeline setup myapp` | `pipeline setup myapp` |
| `/pipeline new myapp bug: login broken` | `pipeline -p myapp new "bug: login broken"` |
| `/pipeline status myapp` | `pipeline -p myapp list open` |
| `/pipeline status myapp 42` | `pipeline -p myapp status 42` |
| `/pipeline assign myapp 42` | `pipeline -p myapp assign 42` |
| `/pipeline pr-ready myapp 42 87` | `pipeline -p myapp pr-ready 42 --pr 87` |
| `/pipeline approve myapp 42` | `pipeline -p myapp approve 42` |
| `/pipeline reject myapp 42 reason` | `pipeline -p myapp reject 42 "reason"` |
| `/pipeline workers myapp` | `pipeline -p myapp workers` |
| `/pipeline takeabreak myapp @Geordi` | `pipeline -p myapp pause <id>` |
| `/pipeline backtowork myapp @Geordi` | `pipeline -p myapp unpause <id>` |

Natural language works too:
- "log a bug for myapp: panel doesn't resize" → `pipeline -p myapp new "bug: panel doesn't resize"`
- "what's open on myapp" → `pipeline -p myapp list open`

## Interactive Setup Wizard

When a user says `/pipeline setup <name>` (or "set up a project", "add a project"), guide them through setup conversationally. Use the inbound message metadata to auto-detect what you can.

### Step 1: Init
```bash
{baseDir}/scripts/pipeline.sh init <name>
```
Skip if project already exists.

### Step 2: GitHub Repo
Ask: "What GitHub repo? (org/repo format)"
```bash
{baseDir}/scripts/pipeline.sh config <name> REPO "<value>"
```
Validate with `gh repo view <value>` — if access fails, ask about tokens.

### Step 3: Guild ID
Auto-detect from inbound message context if available (look for `chat_id` containing a guild).
Otherwise ask. The guild ID from the current Discord server is usually correct.
```bash
{baseDir}/scripts/pipeline.sh config <name> GUILD_ID "<value>"
```

### Step 4: Channels
Ask which channels to use. Need at minimum:
- **Forum channel** (for issue threads) — `FORUM_CHANNEL`
- **PR review channel** — `PR_REVIEW_CHANNEL`
- **Production channel** (optional) — `PRODUCTION_CHANNEL`

List available channels to help the user pick:
```bash
# Use the message tool: message action=channel-list
```
Set each:
```bash
{baseDir}/scripts/pipeline.sh config <name> FORUM_CHANNEL "<id>"
{baseDir}/scripts/pipeline.sh config <name> PR_REVIEW_CHANNEL "<id>"
{baseDir}/scripts/pipeline.sh config <name> PRODUCTION_CHANNEL "<id>"
```

### Step 5: Webhooks
Create automatically — no user input needed:
```bash
{baseDir}/scripts/pipeline.sh create-webhooks <name>
```

### Step 6: Forum Tags
Auto-detect from the forum channel:
```bash
{baseDir}/scripts/pipeline.sh fetch-tags <name>
```
This auto-maps tags named "bug", "feature", "resolved" etc.

### Step 7: GitHub Token (if needed)
If `gh repo view` failed, ask for the token file path:
```bash
{baseDir}/scripts/pipeline.sh config <name> 'export GH_TOKEN' '$(cat "/path/to/token" 2>/dev/null)'
```

### Step 8: Validate
```bash
{baseDir}/scripts/pipeline.sh setup <name>
```
Show results. If all green, tell the user they're ready.

### Shortcut
If the user provides everything at once ("set up pipeline for Obsolete-Robot/myapp using forum channel X, review channel Y"), skip the Q&A and just run all the commands in sequence.

## Workflow Commands

All require `-p <project>`:

```
pipeline -p <proj> new "type: description"     # Create issue + forum thread
pipeline -p <proj> new "bug: x" --no-auto-merge # Same but requires manual merge
pipeline -p <proj> assign <num>                # Post to thread (@mention agent)
pipeline -p <proj> pr-ready <num> --pr <pr>    # Post review request to thread
pipeline -p <proj> approve <num>               # Merge + deploy + close + archive
pipeline -p <proj> reject <num> "reason"       # Post feedback to thread
pipeline -p <proj> close <num> "reason"        # Close + notify channels + archive
pipeline -p <proj> status [num]                # Show issue state
pipeline -p <proj> list [open|all]             # List issues
```

## Per-Project Deploy Config

Projects can define deploy steps in their `.conf`:

```bash
# Deploy steps (run after merge)
DEPLOY_STEPS='cd /srv/myapp && git pull && docker-compose restart'

# Post-deploy reminders
DEPLOY_POST_NOTES="Remember to clear CDN cache after deploy."
```

When `approve` merges a PR and `DEPLOY_STEPS` is defined, the pipeline:
1. Runs the deploy commands
2. Posts success/failure to #production via webhook

## Admin Commands (no -p needed)

```
pipeline projects                    # List all configured projects
pipeline init <name>                 # Scaffold new project
pipeline setup <name>               # Validate setup
pipeline config <name> KEY value    # Set a config value
pipeline config-show <name>         # Show current config
pipeline create-webhooks <name>     # Auto-create Discord webhooks
pipeline fetch-tags <name>          # Auto-detect forum tags
```

## Worker Pool

Multiple bots can share the workload. Set `WORKER_BOT_IDS` in the project config (space-separated Discord user IDs):

```bash
pipeline config myapp WORKER_BOT_IDS "1467918736836268035 1234567890 9876543210"
```

On `assign`, the pipeline auto-selects the worker with the fewest active issues (oldest idle as tiebreaker). Each issue tracks which worker was assigned, so all subsequent @mentions (approve, reject, feedback) go to the right bot.

Check pool status:
```
/pipeline workers myapp
```

Falls back to `DEFAULT_WORKER_ID` if `WORKER_BOT_IDS` is empty (single-bot mode).

## Issue Types

Prefix description: `bug:`, `feature:`, `task:`

## Dependencies

`gh`, `jq`, `node`, `curl`, Discord bot token at `~/.config/discord/bot-token`
