---
name: codex-build
description: Delegate an implementation task from Claude Code to Codex CLI in one visible Zellij session, with repo authority and verification context bundled automatically. Use when the user asks Claude to have Codex build or implement a plan, says "send this to Codex" or "delegate this build", or invokes `/codex-build`.
---

# Codex Build

Use Codex as the implementation worker while Claude keeps the planning and review role. Launch one visible session, let Codex work in the target repo, then judge the actual diff before reporting success.

## Defaults

- Model: Sol (`gpt-5.6-sol`).
- Reasoning effort: `high`.
- Sandbox: `workspace-write`.
- Zellij socket: automatic stable per-user path when `ZELLIJ_SOCKET_DIR` is unset.
- Session name: collision-safe generated name.

Override model, effort, or sandbox only when the user or task requires it.

## Launch

1. Confirm the target Git repo root. Do not launch from a parent containing unrelated repos.
2. Capture the implementation request as either a plan file or concise intent.
3. Run from the target repo:

```sh
/path/to/codex-build/scripts/codex_build.rb --plan docs/plan.md
/path/to/codex-build/scripts/codex_build.rb --intent "Implement the broker sync"
```

The helper automatically bundles ancestor and repo authority files, including `AGENTS.md`, `CLAUDE.md`, and repo-root `.claude/CLAUDE.md`. It also records the pre-run status and diff so existing changes are not misattributed to Codex.

Useful options:

- `--check CMD` supplies the completion check when authority files do not name one.
- `--model MODEL`, `--effort LEVEL`, and `--sandbox MODE` override defaults.
- `--dry-run` prints the exact prompt and command settings.
- `--doctor` checks installed dependencies; no shell socket setup is required.
- `--no-terminal` skips Ghostty auto-open while keeping the Zellij session.

## Observe

Let the user watch the visible pane. Prefer the printed bounded watcher in Claude Code. Otherwise check the done marker after 2-3 minutes. Treat the marker, last-message file, run log, and `build.error` as the completion truth; do not diagnose from pane appearance alone.

Leave the session open for follow-up work. Clean it up only when the user says the run is finished.

## Review and Stop

Codex's last message is evidence, not the result. After a successful marker:

1. Compare current status and diff with the pre-run snapshot.
2. Review the actual implementation against the plan, repo authority, and behavioural correctness.
3. Run the named check command.
4. Stop at this checkpoint before editing:

```md
Codex implemented: [summary from the diff]

Holds up:
- [decision]: [why]

Worth changing:
- [finding]: [smallest fix]

Open questions:
- [user decision]

Checks: [command and result]

Next steps:
- [accepted-finding plan]
```

Skip empty sections. If nothing needs changing, say so and name any residual risk.

## Feedback

After the user accepts findings, send only those findings back to the same Codex session:

```sh
/path/to/codex-build/scripts/codex_build.rb \
  --feedback "Fix only these accepted findings: ..."
```

The feedback run resumes the latest Codex session and inherits its model and reasoning effort. Pass `--model` or `--effort` explicitly only when the follow-up should change them.

## Do Not Use For

- Code review or fresh-eyes review.
- Open-ended diagnosis where the cause is still unknown.
- Work Claude should implement directly in the current session.
