---
name: codex-build
description: Delegate an implementation task to Codex CLI in a visible Zellij pane, injecting AGENTS.md project constraints into the brief. Use when the user wants to implement a plan or PRD with Codex, says "have Codex build this", "send this to Codex", "delegate to Codex", or "/codex-build".
---

# codex-build

Delegate an implementation task to Codex. The script reads the repo's AGENTS.md (or CLAUDE.md),
builds a structured prompt with project constraints, and launches `codex exec` in a visible Zellij
pane. A done-marker and last-message file let you poll for completion without blocking the session.

## Requirements

- Zellij: `brew install zellij`
- `ZELLIJ_SOCKET_DIR` in shell startup: `export ZELLIJ_SOCKET_DIR=/tmp/zellij`
- Codex CLI installed and authenticated: `npm install -g @openai/codex && codex login`
- Ghostty for the auto-opened attach tab (optional — without it, use the printed
  `zellij attach` command from any terminal)

## Run the script

The skill base directory is shown in the system-reminder as "Base directory for this skill: PATH".
Refer to it as `$SKILL_BASE` below.

1. Confirm you are inside a git repo.
2. Collect the plan path (`--plan PATH`) or intent string (`--intent "..."`) from the request.
3. Run the script from the project repo root:

```sh
ruby $SKILL_BASE/scripts/codex_build.rb --plan docs/plan.md
ruby $SKILL_BASE/scripts/codex_build.rb --intent "implement the broker sync"
```

Useful flags:

```sh
# Supply the check command explicitly (auto-detected from AGENTS.md if omitted)
ruby $SKILL_BASE/scripts/codex_build.rb --plan docs/plan.md --check "bundle exec rake check"

# Tune model and effort
ruby $SKILL_BASE/scripts/codex_build.rb --plan docs/plan.md --effort high --model gpt-5.4-mini

# Verify the prompt before sending
ruby $SKILL_BASE/scripts/codex_build.rb --plan docs/plan.md --dry-run

# Skip opening a terminal window attached to the session
ruby $SKILL_BASE/scripts/codex_build.rb --plan docs/plan.md --no-terminal
```

4. The script prints the done-marker path and completion check command. Share these with the user
   so they know how to observe the run.

## After Codex finishes

Once the done marker appears:

1. Read the last-message file (path printed by the script).
2. Offer to run `/codex:adversarial-review --base HEAD` to review what Codex changed.
3. Report the summary and ask how to proceed.

## Observation policy

Let the user watch in Zellij. Check the done marker after 2-3 minutes, then poll cheaply:
`test -f /tmp/codex-build-SESSION/build.done`. Inspect the pane only on request or to diagnose
a stall. Use `dump-screen` (viewport only) rather than full transcript dumps.

## Do not use for

- Code review — use `/codex:review` or `/codex:adversarial-review`
- Bug investigation — use `/codex:rescue`
- Tasks Claude can complete directly in the current session
