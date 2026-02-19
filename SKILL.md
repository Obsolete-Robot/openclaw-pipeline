---
name: pipeline
description: >
  Issue-to-PR pipeline orchestrator. Use when the user wants to create issues, assign work,
  review PRs, or manage a development workflow. Triggers on "pipeline", "new issue", "new bug",
  "log a bug", "log an issue", "assign issue", "pr ready", "approve pr", "reject pr",
  "pipeline status", "pipeline setup", "pipeline init". Also handles /pipeline slash command.
user-invocable: true
---

# Pipeline — Issue→PR Orchestrator

State machine for the full issue→PR lifecycle. Each task spawns a FRESH isolated session.

Script: `{baseDir}/scripts/pipeline.sh`
Projects: `{baseDir}/projects/<name>.conf`

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
pipeline -p <proj> assign <num>                # Spawn worker session
pipeline -p <proj> pr-ready <num> --pr <pr>    # Spawn reviewer session
pipeline -p <proj> approve <num>               # Merge + close + archive
pipeline -p <proj> reject <num> "reason"       # Spawn fix session
pipeline -p <proj> close <num>                 # Manual close
pipeline -p <proj> status [num]                # Show issue state
pipeline -p <proj> list [open|all]             # List issues
```

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

## Issue Types

Prefix description: `bug:`, `feature:`, `task:`

## Dependencies

`gh`, `jq`, `node`, `curl`, `openclaw` CLI, Discord bot token at `~/.config/discord/bot-token`
