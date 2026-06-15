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

The done marker contains Codex's exit code. Once it appears:

1. Read the marker. `0` means Codex finished; anything else means the run failed.
2. On success, read the last-message file, then review the implementation (below).
3. On failure, dump the pane tail to diagnose
   (`zellij --session SESSION action dump-screen --pane-id PANE`) and report the
   error — do not present the run as complete.

## Review the implementation

Codex's last message is its own summary of its own work. Do not relay it as the
result — review the actual diff first (`git status --short`, `git diff`, and any
new untracked files).

Reviewer posture: pragmatic review for a serious small experiment. Judge the
diff against, in order:

1. **The plan** — was it followed? Did Codex deviate, and did it call the
   deviation out and justify it? An unannounced deviation is a finding even
   when the code is fine.
2. **Project constraints** — the repo's AGENTS.md rules: style, stack, scope,
   privacy/safety boundaries. A violation of a stated rule is a finding.
3. **Correctness** — bugs, broken flows, tests that pass without testing the
   behavior, missing essential cases.

Do not be pedantic: no style preferences beyond the project's stated rules, no
speculative scale or robustness concerns, no "this might matter someday"
findings, no refactors the plan did not ask for.

Run the project's check command and include the result.

Then walk the user through what came back and stop for their go-ahead before
editing:

```md
Codex implemented: [one-paragraph summary, from the diff not the last message]

Holds up:
- [decision]: [why it is right]

Worth changing:
- [finding]: [why, and the smallest fix]

Open questions:
- [anything only the user can decide — scope, tradeoffs, taste]

Checks: [check command result]

Next steps:
- [ordered fixes; for each, whether to fix directly or loop back to Codex]
```

If nothing is worth changing, say so plainly and note any residual risk or test
gap. Skip empty sections.
When the diff is large, touches a trust or privacy boundary, or your confidence
is low, escalate to a deeper independent review (a second reviewer or a dedicated
review tool) rather than treating this pass as the last word. Not by default.

## Observation policy

Let the user watch in Zellij. Check the done marker after 2-3 minutes, then poll cheaply:
`test -f /tmp/codex-build-SESSION/build.done`. Inspect the pane only on request, on a non-zero
marker, or to diagnose a stall. Use `dump-screen` (viewport only) rather than full transcript dumps.

## Do not use for

- Code review: use a dedicated code-review tool or fresh-eyes review pass
- Bug investigation: drive it directly, or use a debugging-focused tool
- Tasks Claude can complete directly in the current session
