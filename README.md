# Pipeline — Issue→PR Orchestrator for OpenClaw

A dumb state machine that manages the full GitHub issue → Discord thread → PR → review → merge lifecycle without burning LLM tokens on message routing.

Each step spawns a **fresh isolated OpenClaw session** — zero context accumulation, zero role confusion.

## What It Does

| Step | Pipeline Bot (deterministic) | LLM Session (smart) |
|------|------------------------------|---------------------|
| `new` | Creates GitHub issue + Discord forum thread | Writes the issue spec |
| `assign` | Posts context to thread, tracks state | Codes the fix (fresh session) |
| `pr-ready` | Notifies reviewers, updates thread | — |
| `approve` | Merges PR, closes issue, archives thread | — |
| `reject` | Posts feedback, spawns fix session | Addresses review feedback (fresh session) |

## Install

Copy into your OpenClaw workspace skills directory:

```bash
# Via ClawHub (when published)
clawhub install pipeline

# Or manually
git clone https://github.com/Obsolete-Robot/openclaw-pipeline.git \
  ~/.openclaw/workspace/skills/pipeline
```

Restart OpenClaw to pick up the skill. `/pipeline` slash command appears in Discord.

## Setup

Everything can be done from Discord:

```
/pipeline setup myproject
```

The bot walks you through:
1. GitHub repo
2. Discord guild + channels (forum, PR review, production)
3. Auto-creates webhooks
4. Auto-detects forum tags
5. Validates everything

Or via CLI:

```bash
pipeline init myproject
pipeline config myproject REPO "org/repo"
pipeline config myproject GUILD_ID "123456"
pipeline config myproject FORUM_CHANNEL "789"
pipeline config myproject PR_REVIEW_CHANNEL "012"
pipeline create-webhooks myproject
pipeline fetch-tags myproject
pipeline setup myproject
```

## Onboarding Worker Bots

When adding an OpenClaw bot as a worker, its **OpenClaw config** must be set up to receive webhook messages from the pipeline. This is the most common source of "bot doesn't respond to assignments" issues.

### Requirements

The worker bot's `openclaw.json` needs:

#### 1. `allowBots: true`

Webhook messages are flagged as bot messages by Discord. Without this, they're silently dropped.

```json5
{
  "channels": {
    "discord": {
      "allowBots": true
    }
  }
}
```

#### 2. Webhook IDs in the guild's `users` allowlist

**This is the one everyone misses.** If the guild uses `groupPolicy: "allowlist"` (recommended), the `users` array controls who can trigger the bot. Webhook authors must be in this list or their messages are **silently dropped**.

Get webhook IDs from the webhook URLs:
```
https://discord.com/api/webhooks/{WEBHOOK_ID}/{token}
                                  ^^^^^^^^^^^
```

Add them to the worker's config:

```json5
{
  "channels": {
    "discord": {
      "groupPolicy": "allowlist",
      "guilds": {
        "YOUR_GUILD_ID": {
          "users": [
            "human_user_id_1",
            "human_user_id_2",
            "FORUM_WEBHOOK_ID",      // ← pipeline webhook IDs
            "REVIEWS_WEBHOOK_ID",
            "PRODUCTION_WEBHOOK_ID"
          ]
        }
      }
    }
  }
}
```

You can find the webhook IDs for a project with:
```bash
# From the pipeline host machine
for f in ~/.config/discord/projects/<project>/*-webhook; do
  echo "$(basename $f): $(grep -oP 'webhooks/\K[0-9]+' $f)"
done
```

#### 3. Forum channel allowed

The forum channel where threads are created must be `allow: true`:

```json5
{
  "channels": {
    "discord": {
      "guilds": {
        "YOUR_GUILD_ID": {
          "channels": {
            "FORUM_CHANNEL_ID": {
              "allow": true,
              "requireMention": true
            }
          }
        }
      }
    }
  }
}
```

Thread access is automatic — OpenClaw sees messages in threads under allowed channels.

#### 4. Restart the worker bot

After config changes, restart the worker's gateway:
```bash
openclaw gateway restart
# or send SIGUSR1 to the gateway process
kill -USR1 $(pgrep -f 'openclaw-gateway')
```

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Bot ignores all webhook messages | `allowBots` not set | Add `allowBots: true` to `channels.discord` |
| Bot ignores webhook messages in one guild | Webhook ID not in `users` array | Add webhook IDs to the guild's `users` allowlist |
| Bot ignores messages in forum threads | Forum channel not allowed | Set `allow: true` on the forum channel |
| Bot responds to some webhooks but not others | Missing specific webhook ID | Check all pipeline webhook IDs are in `users` |
| Slash commands work but webhooks don't | Commands bypass allowlist, webhooks don't | Add webhook IDs to `users` |

### Quick Onboarding Checklist

- [ ] `allowBots: true` in `channels.discord`
- [ ] All pipeline webhook IDs added to guild `users` array
- [ ] Forum channel set to `allow: true`
- [ ] PR review channel set to `allow: true` (if bot reviews PRs)
- [ ] Bot restarted after config changes
- [ ] Test with: `pipeline -p <project> assign <issue_num>`

## Usage

```bash
# From Discord
/pipeline new myproject bug: login button doesn't work
/pipeline assign myproject 42
/pipeline pr-ready myproject 42 87
/pipeline approve myproject 42
/pipeline reject myproject 42 needs error handling
/pipeline status myproject

# From CLI
pipeline -p myproject new "bug: login button doesn't work"
pipeline -p myproject assign 42
pipeline -p myproject pr-ready 42 --pr 87
pipeline -p myproject approve 42
```

## Worker Pool

Multiple bots can share the workload:

```bash
pipeline config myproject WORKER_BOT_IDS "bot_id_1 bot_id_2 bot_id_3"
```

On assign, the pipeline auto-selects the worker with the fewest active issues. Each issue tracks its assigned worker.

```
/pipeline workers myproject           # show pool status
/pipeline takeabreak myproject @Bot   # put a worker on break
/pipeline backtowork myproject @Bot   # bring them back
```

## Multi-Project

Each project gets its own config + state file. Run multiple projects on the same server or across different servers:

```
/pipeline projects              # list all
/pipeline setup another-app     # add another
```

## Per-Role Models

Different models for different jobs:

```bash
# Workers need the big brain for coding (default: opus)
pipeline config myproject WORKER_MODEL "anthropic/claude-opus-4-6"

# Reviewers and spec writers can use something cheaper (default: sonnet)
pipeline config myproject REVIEWER_MODEL "anthropic/claude-sonnet-4-6"
pipeline config myproject SPEC_MODEL "anthropic/claude-sonnet-4-6"
```

## Dependencies

- `gh` CLI (authenticated)
- `jq`
- `node` (for Discord forum thread creation)
- `curl`
- `openclaw` CLI
- Discord bot token at `~/.config/discord/bot-token`

## How It Works

```
You: "/pipeline new myapp bug: panel broken"
          │
          ▼
    ┌─────────────┐
    │ Pipeline Bot │  (bash script, no LLM)
    │  State: JSON │
    └──────┬──────┘
           │
    ┌──────┴──────────────────────────────┐
    │ 1. Spawn LLM session → issue spec   │
    │ 2. gh issue create                   │
    │ 3. Create Discord forum thread       │
    │ 4. Track in issues.json              │
    └─────────────────────────────────────┘
           │
    "pipeline assign myapp 42"
           │
    ┌──────┴──────────────────────────────┐
    │ 1. Post assignment to thread         │
    │    (@mention selected worker bot)    │
    │ 2. Worker codes fix, creates PR      │
    │ 3. Worker runs: pipeline pr-ready    │
    └─────────────────────────────────────┘
           │
    ┌──────┴──────────────────────────────┐
    │ 1. Spawn FRESH reviewer session      │
    │ 2. Notify #pr-review channel         │
    │ 3. Reviewer approves/rejects         │
    │ 4. Pipeline merges or loops back     │
    └─────────────────────────────────────┘
```

## License

MIT
