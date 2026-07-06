# codex-build

Hand the implementation work to Codex while Claude keeps planning and reviewing, visibly, in one terminal. `codex-build` is an Agent Skill: it reads authority files (`AGENTS.md` then `CLAUDE.md`) from ancestor directories through the repo root, plus repo-root `.claude/CLAUDE.md`, folds those project constraints into a structured brief alongside your plan and check command, and launches `codex exec` in a visible Zellij pane. Claude stays the architect. It writes the plan, delegates the build, then reviews Codex's actual diff against the plan. Because it is a plain Agent Skill, it works in any Agent Skills client: Claude Code, Codex, Cursor, or Gemini CLI.

<!-- Add the demo GIF here once recorded: ![codex-build demo](docs/demo.gif) -->

## Install

```sh
git clone https://github.com/gmchande/codex-build ~/.claude/skills/codex-build
```

That is the Claude Code path. For another Agent Skills client, clone into that client's skills directory instead. Then invoke it with `/codex-build`, or just tell Claude "have Codex build this".

## Requirements

- Codex CLI, installed and authenticated: `npm install -g @openai/codex && codex login`
- Zellij: `brew install zellij`
- `ZELLIJ_SOCKET_DIR` set in your shell startup: `export ZELLIJ_SOCKET_DIR=/tmp/zellij`
- Ruby (ships with macOS)
- macOS with Ghostty for the auto-opened attach tab. This is optional: without it, use the `zellij attach` command the script prints.

Check the local setup with:

```sh
ruby scripts/codex_build.rb --doctor
```

## How it works

1. You give it a plan file (`--plan docs/plan.md`) or a short intent (`--intent "..."`).
2. It reads `AGENTS.md` then `CLAUDE.md` from ancestor directories through the repo root, plus repo-root `.claude/CLAUDE.md`, and folds those house rules into the brief, so Codex builds to your conventions rather than its defaults. Closer files override broader guidance.
3. It detects your check command (for example `bundle exec rake check` or `npm test`) only from repo-root authority files, including repo-root `.claude/CLAUDE.md`, or you pass `--check`.
4. It launches `codex exec` in a visible Zellij pane and opens a Ghostty tab attached to it, so you can watch Codex work and interrupt whenever you want.
5. Before launch, it writes `pre.status` and `pre.diff` in a private temp dir. When Codex exits, it writes a done marker carrying Codex's exit code and a file with Codex's last message. Claude waits on the marker, then reviews the real diff, not Codex's self-summary, against your plan and constraints.

Each run also keeps a `run.log` transcript in the private temp dir. If Codex exits non-zero, the shell epilogue writes the last log lines, with ANSI escape sequences stripped, to `build.error` so failure details survive Zellij session cleanup.

The brief Codex receives is one prompt bundle: the task, the project context from authority files, a short action-safety note, the verification command, and a final-message contract requiring Codex to report files changed, deviations, commands, risks, and questions.

## Flags

```sh
ruby scripts/codex_build.rb --plan docs/plan.md
ruby scripts/codex_build.rb --intent "implement the broker sync"
ruby scripts/codex_build.rb --plan docs/plan.md --check "bundle exec rake check"
ruby scripts/codex_build.rb --plan docs/plan.md --effort high
ruby scripts/codex_build.rb --plan docs/plan.md --model gpt-5.4-mini
ruby scripts/codex_build.rb --plan docs/plan.md --sandbox danger-full-access
ruby scripts/codex_build.rb --feedback "Fix only these accepted review findings: ..."
ruby scripts/codex_build.rb --doctor
ruby scripts/codex_build.rb --plan docs/plan.md --dry-run
ruby scripts/codex_build.rb --plan docs/plan.md --no-terminal
```

In normal use you invoke `/codex-build` and Claude runs the script for you. `--model` overrides the Codex model, `--effort` sets reasoning effort, `--session` names the Zellij session, and `--dry-run` prints the assembled brief without launching anything.

## Feedback Loop

Use `--feedback TEXT` after the review checkpoint, when the user has accepted specific findings and you want Codex to fix them in the same session. It runs `codex exec resume --last` from the repo root, sends only a small feedback prompt, and does not re-send the project context bundle. `--feedback` is mutually exclusive with `--plan` and `--intent`.

`--dry-run --feedback "..."` prints the resume command and feedback prompt. Before a real feedback launch, the script checks `codex exec resume --help` and passes only resume-supported flags; explicit `--model` and `--effort` are omitted when the installed Codex CLI does not support them on resume.

## Review and Observation

If the launch output says the tree was dirty, compare the current `git status --short` and `git diff` against the printed `pre.status` and `pre.diff` snapshot paths before attributing changes to Codex.

For harness-driven use, prefer the printed bounded background watcher command. Claude Code re-invokes the session when a background command exits, so this is better than periodic polling. For other clients, fall back to checking the done marker after 2-3 minutes, then polling cheaply.

After triage is complete, run the printed cleanup command. If the session is still attached, run `zellij kill-session SESSION` first, then `zellij delete-session --force SESSION`. Skipping cleanup accumulates dead sessions.

## Security

Codex runs in the `workspace-write` sandbox by default: it can read your machine and write inside the repo, but not the wider filesystem, and it does not get the unrestricted disk and network access that the riskier mode grants. For a task that genuinely needs more, such as installing dependencies, opt up explicitly with `--sandbox danger-full-access`. Only do that in a repo you trust, ideally on a branch or an isolated worktree, because that mode removes the guardrails.

## Limitations

- macOS-first. The Ghostty auto-attach is macOS only. On Linux, pass `--no-terminal` and attach with the printed `zellij attach` command.
- Requires Zellij and the Codex CLI on your `PATH`, and Codex must be authenticated separately with `codex login`.
- The visible-pane workflow is the point. There is no hidden background mode.

## Licence

MIT. See [LICENSE](LICENSE).
