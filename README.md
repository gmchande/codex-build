# codex-build

Hand the implementation work to Codex while Claude keeps planning and reviewing, visibly, in one terminal. `codex-build` is an Agent Skill: it reads your repo's `AGENTS.md` (or `CLAUDE.md`), folds those project constraints into a structured brief alongside your plan and check command, and launches `codex exec` in a visible Zellij pane. Claude stays the architect. It writes the plan, delegates the build, then reviews Codex's actual diff against the plan. Because it is a plain Agent Skill, it works in any Agent Skills client: Claude Code, Codex, Cursor, or Gemini CLI.

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

## How it works

1. You give it a plan file (`--plan docs/plan.md`) or a short intent (`--intent "..."`).
2. It reads `AGENTS.md` or `CLAUDE.md` and folds those house rules into the brief, so Codex builds to your conventions rather than its defaults.
3. It detects your check command (for example `bundle exec rake check` or `npm test`) from that file, or you pass `--check`.
4. It launches `codex exec` in a visible Zellij pane and opens a Ghostty tab attached to it, so you can watch Codex work and interrupt whenever you want.
5. When Codex exits, the script writes a done marker carrying Codex's exit code and a file with Codex's last message. Claude polls the marker, then reviews the real diff, not Codex's self-summary, against your plan and constraints.

The brief Codex receives is one prompt bundle: the task, the project context from `AGENTS.md`, a short action-safety note, and the verification command.

## Flags

```sh
ruby scripts/codex_build.rb --plan docs/plan.md
ruby scripts/codex_build.rb --intent "implement the broker sync"
ruby scripts/codex_build.rb --plan docs/plan.md --check "bundle exec rake check"
ruby scripts/codex_build.rb --plan docs/plan.md --effort high
ruby scripts/codex_build.rb --plan docs/plan.md --sandbox danger-full-access
ruby scripts/codex_build.rb --plan docs/plan.md --dry-run
ruby scripts/codex_build.rb --plan docs/plan.md --no-terminal
```

In normal use you invoke `/codex-build` and Claude runs the script for you. `--model` overrides the Codex model, `--session` names the Zellij session, and `--dry-run` prints the assembled brief without launching anything.

## Security

Codex runs in the `workspace-write` sandbox by default: it can read your machine and write inside the repo, but not the wider filesystem, and it does not get the unrestricted disk and network access that the riskier mode grants. For a task that genuinely needs more, such as installing dependencies, opt up explicitly with `--sandbox danger-full-access`. Only do that in a repo you trust, ideally on a branch or an isolated worktree, because that mode removes the guardrails.

## Limitations

- macOS-first. The Ghostty auto-attach is macOS only. On Linux, pass `--no-terminal` and attach with the printed `zellij attach` command.
- Requires Zellij and the Codex CLI on your `PATH`, and Codex must be authenticated separately with `codex login`.
- The visible-pane workflow is the point. There is no hidden background mode.

## Licence

MIT. See [LICENSE](LICENSE).
