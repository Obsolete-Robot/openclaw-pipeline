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

## Multi-Project

Each project gets its own config + state file. Run multiple projects on the same server or across different servers:

```
/pipeline projects              # list all
/pipeline setup another-app     # add another
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
    │ 1. Spawn FRESH worker session        │
    │    (gets only issue context)         │
    │ 2. Post assignment to thread         │
    │ 3. Worker codes fix, creates PR      │
    │ 4. Worker runs: pipeline pr-ready    │
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
