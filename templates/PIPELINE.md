# PIPELINE.md — Pipeline Guide

> **This file is the single source of truth for all pipeline bots.**
> If you're working on an issue or reviewing a PR for this project, read this first.

## Project Overview

<!-- Brief description of what this project is and does -->

## Tech Stack

<!-- Languages, frameworks, key dependencies -->

## Repository Layout

<!-- Key directories and what lives where -->

## Development Setup

```bash
# How to get the project running locally (if needed for testing)
```

## Coding Standards

<!-- Style guide, linting rules, naming conventions -->

## Common Gotchas

<!-- Things that trip people up in this codebase -->

## Branch & PR Conventions

- Branch naming: `issue-<num>` (auto-created by pipeline)
- PR target: `dev` (or as configured)
- Squash merge by default
- PR description should reference the issue number

## Testing

<!-- How to run tests, what coverage is expected -->

## Post-Merge / Deploy

<!-- What happens after a PR is merged -->
<!-- Deploy steps, cache busting, service restarts -->

## Review Criteria

<!-- What reviewers look for -->
<!-- Security, error handling, test coverage, etc. -->

---

## Pipeline Roles

You may be acting as a **worker** (assigned an issue) or an **orchestrator/reviewer** (asked to review a PR). The pipeline assigns roles via @mentions in Discord forum threads.

### If You're a Worker

You were @mentioned with an issue assignment. Follow the instructions in that message:
1. Read this file first
2. Create a worktree, do the work
3. Create a PR, then request a review (the assign message has a curl command for this)
4. Wait for review feedback in the thread
5. **Never self-review, self-approve, or self-merge**

### If You're Asked to Review a PR

You were @mentioned with a review request (typically from a webhook message containing "review PR #X"). Here's what to do:

1. **Fetch the diff:**
   ```bash
   gh pr diff <PR_NUM> --repo <OWNER/REPO>
   ```

2. **Read this file** for project context and review criteria (above).

3. **Review the code for:**
   - Correctness and edge cases
   - Error handling
   - Security concerns
   - Code quality and readability
   - Adherence to coding standards (see above)

4. **Post your review to GitHub:**
   - Approve: `gh pr review <PR_NUM> --repo <OWNER/REPO> --approve --body "summary"`
   - Request changes: `gh pr review <PR_NUM> --repo <OWNER/REPO> --request-changes --body "feedback"`

5. **Run the pipeline command to advance the state:**
   ```bash
   ~/.openclaw/workspace/skills/pipeline/scripts/pipeline.sh -p <PROJECT> approve <ISSUE_NUM>
   # or
   ~/.openclaw/workspace/skills/pipeline/scripts/pipeline.sh -p <PROJECT> reject <ISSUE_NUM> "feedback"
   ```
   If you don't have the pipeline script, post your verdict in the thread and a human or orchestrator will handle it.

6. **Post a summary in the thread** so the worker (and humans) can see the result.

### Key Rules (All Roles)
- **Workers never review/approve/merge their own PRs**
- **Reviewers are independent** — give honest feedback, don't rubber-stamp
- **Everything happens in the thread** — keep it visible
- **When in doubt, ask in the thread** — humans are watching

---

*Single source of truth for all pipeline bots. Customize the sections above for your project.*
