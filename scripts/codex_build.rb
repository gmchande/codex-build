#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "shellwords"
require "tmpdir"

CONTEXT_FILES   = %w[AGENTS.md CLAUDE.md .claude/CLAUDE.md].freeze
MAX_CONTEXT_BYTES = 100_000
MAX_PLAN_BYTES    = 200_000
CHECK_PATTERNS  = [
  /bundle exec rake \w+/,
  /rake (?:check|test)/,
  /npm test/,
  /yarn test/,
  /make test/,
  /pytest/,
  /go test/,
].freeze

options = {
  plan:       nil,
  intent:     nil,
  check:      nil,
  session:    nil,
  sandbox:    "workspace-write",
  effort:     nil,
  model:      nil,
  dry_run:     false,
  no_terminal: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: codex_build.rb [options]"
  opts.on("--plan PATH",    "Plan or PRD file to implement")                                { |v| options[:plan]       = v }
  opts.on("--intent TEXT",  "Short intent string (alternative to --plan)")                  { |v| options[:intent]     = v }
  opts.on("--check CMD",    "Check command to run on completion (auto-detected if omitted)") { |v| options[:check]     = v }
  opts.on("--session NAME", "Zellij session name (default: codex-build-HHMMSS)")            { |v| options[:session]   = v }
  opts.on("--sandbox MODE", "Codex sandbox mode (default: workspace-write)")             { |v| options[:sandbox]   = v }
  opts.on("--effort LEVEL", "Codex reasoning effort (none|minimal|low|medium|high|xhigh)") { |v| options[:effort]    = v }
  opts.on("--model MODEL",  "Codex model")                                                   { |v| options[:model]    = v }
  opts.on("--dry-run",      "Print the prompt bundle without running")                      {      options[:dry_run]     = true }
  opts.on("--no-terminal",  "Skip opening a terminal window attached to the session")       {      options[:no_terminal] = true }
  opts.on("-h", "--help",   "Show help") { puts opts; exit 0 }
end.parse!(ARGV)

def run_command(*cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*cmd)
  if !status.success? && !allow_failure
    warn "Command failed: #{cmd.shelljoin}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end
  [stdout, stderr, status]
end

def command_available?(name)
  _stdout, _stderr, status = run_command(
    "sh", "-c", "command -v #{Shellwords.escape(name)} >/dev/null 2>&1",
    allow_failure: true
  )
  status.success?
end

def inside_git_repo?
  _stdout, _stderr, status = run_command("git", "rev-parse", "--is-inside-work-tree", allow_failure: true)
  status.success?
end

def git_repo_root
  stdout, _stderr, _status = run_command("git", "rev-parse", "--show-toplevel")
  stdout.strip
end

def session_name(options)
  return options[:session] if options[:session]

  "codex-build-#{Time.now.strftime("%H%M%S")}"
end

def find_context_file(root)
  CONTEXT_FILES.map { |f| File.join(root, f) }.find { |p| File.file?(p) }
end

def truncate_text(text, max_bytes, label)
  return [text, false] if text.bytesize <= max_bytes

  truncated = text.byteslice(0, max_bytes).to_s.scrub
  ["#{truncated}\n\n... #{label} truncated at #{max_bytes} bytes ...", true]
end

def extract_check_command(text)
  # Earliest match in the file wins, not first pattern in the list: a doc that
  # leads with its check command should beat an incidental mention later on.
  CHECK_PATTERNS.filter_map { |pattern| text.match(pattern) }.min_by { |m| m.begin(0) }&.to_s
end

def read_plan(path)
  return nil unless path

  unless File.file?(path)
    warn "Plan file not found: #{path}"
    exit 1
  end

  truncate_text(File.read(path), MAX_PLAN_BYTES, "plan").first
end

def build_prompt(plan_text:, intent:, context_text:, check_cmd:, repo_root:, session:)
  task_content = plan_text || intent
  parts = ["<task>\n#{task_content.strip}\n</task>"]

  if context_text
    parts << "<project_context>\nRepository: #{repo_root}\n\n#{context_text.strip}\n</project_context>"
  end

  parts << <<~XML.chomp
    <action_safety>
    Keep changes tightly scoped to the stated task.
    Avoid unrelated refactors, renames, or cleanup unless required for correctness.
    Call out any risky or irreversible action before taking it.
    </action_safety>
  XML

  parts << "<verification>\nWhen done, run: #{check_cmd}\n</verification>" if check_cmd

  "# Codex Build — #{File.basename(repo_root)} / #{session}\n\n" + parts.join("\n\n")
end

def ensure_command!(name, install_hint)
  return if command_available?(name)

  warn "#{name} not found on PATH."
  warn install_hint
  exit 1
end

def ensure_zellij_socket_dir!
  socket_dir = ENV.fetch("ZELLIJ_SOCKET_DIR", "")
  if socket_dir.empty?
    warn "ZELLIJ_SOCKET_DIR is not set."
    warn "Add to shell startup: export ZELLIJ_SOCKET_DIR=/tmp/zellij"
    warn "Then open a new terminal and rerun."
    exit 1
  end

  begin
    FileUtils.mkdir_p(socket_dir)
  rescue SystemCallError => e
    warn "Could not create ZELLIJ_SOCKET_DIR #{socket_dir.inspect}: #{e.message}"
    exit 1
  end
end

def setup_temp_dir(session)
  dir = File.join(Dir.tmpdir, "codex-build-#{session}")
  FileUtils.mkdir_p(dir)
  dir
end

def zellij(*args, allow_failure: false)
  stdout, stderr, status = run_command("zellij", *args, allow_failure: true)
  if !status.success? && !allow_failure
    warn "zellij #{args.shelljoin} failed"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end
  [stdout, stderr, status]
end

def zellij_session_exists?(name)
  stdout, _stderr, status = zellij("list-sessions", "--short", allow_failure: true)
  return false unless status.success?

  stdout.lines.map(&:strip).include?(name)
end

def delete_zellij_session(name)
  zellij("delete-session", "--force", name, allow_failure: true)
end

def launch_codex_pane(session:, repo_root:, task_path:, last_msg_path:, done_path:, sandbox:, effort:, model:)
  codex_cmd = ["codex", "exec", "--sandbox", sandbox, "-o", last_msg_path]
  codex_cmd.push("-c", "model_reasoning_effort=#{effort}") if effort
  codex_cmd.push("-m", model) if model
  codex_cmd.push("-")

  # The marker is always written and carries codex's exit code, so a failed run
  # (auth error, CLI crash) is distinguishable from success without inspecting
  # the pane. `touch` or `&&` would make failure look like a hung or green run.
  shell_cmd = "#{codex_cmd.shelljoin} < #{task_path.shellescape}; echo $? > #{done_path.shellescape}"

  _stdout, stderr, status = zellij("attach", "--create-background", session, allow_failure: true)
  unless status.success?
    warn "Failed to create Zellij session '#{session}': #{stderr.strip}"
    exit 1
  end

  stdout, stderr, status = zellij(
    "--session", session,
    "run", "--cwd", repo_root, "--name", "Codex Build",
    "--", "sh", "-lc", shell_cmd,
    allow_failure: true
  )
  unless status.success?
    warn "Failed to launch pane in Zellij session '#{session}': #{stderr.strip}"
    delete_zellij_session(session)
    exit 1
  end

  pane_id = stdout.strip
  if pane_id.empty?
    warn "Zellij did not return a pane ID."
    delete_zellij_session(session)
    exit 1
  end

  close_other_terminal_panes(session, pane_id)
  pane_id
end

def close_other_terminal_panes(session, pane_id)
  # `attach --create-background` seeds the session with a default shell pane;
  # close it so the attached view shows only the Codex pane.
  stdout, _stderr, status = zellij("--session", session, "action", "list-panes", allow_failure: true)
  return unless status.success?

  stdout.each_line do |line|
    other_pane_id = line[/\A(terminal_\d+)\s+terminal\b/, 1]
    next if other_pane_id.nil? || other_pane_id == pane_id

    zellij("--session", session, "action", "close-pane", "--pane-id", other_pane_id, allow_failure: true)
  end
end

def applescript_string(value)
  "\"#{value.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')}\""
end

def ghostty_script(attach_cmd, repo_root)
  <<~APPLESCRIPT
    tell application "Ghostty"
      set cfg to new surface configuration
      set initial working directory of cfg to #{applescript_string(repo_root)}
      set command of cfg to #{applescript_string(attach_cmd)}
      set wait after command of cfg to true
      if (count of windows) > 0 then
        set newTab to new tab in front window with configuration cfg
        select tab newTab
      else
        set newWin to new window with configuration cfg
      end if
      activate
    end tell
  APPLESCRIPT
end

def open_terminal_window(session, repo_root)
  socket_dir  = ENV.fetch("ZELLIJ_SOCKET_DIR", "")
  attach_inner = "export ZELLIJ_SOCKET_DIR=#{socket_dir.shellescape}; " \
                 "zellij attach #{session.shellescape}; exec /bin/zsh -l"
  attach_cmd  = "/bin/zsh -lc #{Shellwords.escape(attach_inner)}"

  _stdout, _stderr, status = Open3.capture3("osascript", stdin_data: ghostty_script(attach_cmd, repo_root))
  status.success?
end

def print_observation_info(session:, pane_id:, task_path:, last_msg_path:, done_path:, terminal_opened:)
  puts "Codex build started in Zellij session: #{session}"
  puts "Zellij pane:  #{pane_id}"
  puts "Task bundle:  #{task_path}"
  puts "Last message: #{last_msg_path}"
  puts "Done marker:  #{done_path}"
  puts

  unless terminal_opened
    puts "Attach:"
    puts "  zellij attach #{session.shellescape}"
    puts
  end

  puts "Completion check (marker holds codex's exit code):"
  puts "  test -f #{done_path.shellescape} && cat #{done_path.shellescape}"
  puts "  test -f #{done_path.shellescape} && [ \"$(cat #{done_path.shellescape})\" = \"0\" ] && cat #{last_msg_path.shellescape}"
  puts
  puts "Interrupt:"
  puts "  zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id} Esc"
  puts "  zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id} \"Ctrl c\""
  puts
  puts "Observe (viewport only):"
  puts "  zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id}"
  puts
  puts "Observation policy: check the done marker after 2-3 minutes; inspect the pane only on request or to diagnose a stall."
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

unless options[:plan] || options[:intent]
  warn "Provide --plan PATH or --intent TEXT."
  exit 1
end

unless inside_git_repo?
  warn "Not inside a git repository. Run from the project repo you want Codex to build."
  exit 1
end

# Resolve the plan path against the invoking directory before chdir to the repo
# root, so a cwd-relative --plan works when invoked from a subdirectory.
options[:plan] = File.expand_path(options[:plan]) if options[:plan]

root    = git_repo_root
Dir.chdir(root)
session = session_name(options)

context_path = find_context_file(root)
context_text = context_path && truncate_text(File.read(context_path), MAX_CONTEXT_BYTES, "context").first
check_cmd    = options[:check] || (context_text && extract_check_command(context_text))
plan_text    = read_plan(options[:plan])

prompt = build_prompt(
  plan_text:    plan_text,
  intent:       options[:intent],
  context_text: context_text,
  check_cmd:    check_cmd,
  repo_root:    root,
  session:      session
)

if options[:dry_run]
  puts "Sandbox: #{options[:sandbox]}"
  puts "Effort:  #{options[:effort] || "(codex default)"}"
  puts "Model:   #{options[:model]  || "(codex default)"}"
  puts "Session: #{session}"
  puts "Context: #{context_path    || "(none found)"}"
  puts "Check:   #{check_cmd       || "(none)"}"
  puts
  puts "## Prompt bundle"
  puts
  puts prompt
  exit 0
end

ensure_command!("zellij", "Install with: brew install zellij")
ensure_command!("codex",  "Install with: npm install -g @openai/codex, then: codex login")
ensure_zellij_socket_dir!

if zellij_session_exists?(session)
  warn "Zellij session '#{session}' already exists. Use --session NAME to choose a different name."
  exit 1
end

temp_dir      = setup_temp_dir(session)
task_path     = File.join(temp_dir, "task.md")
last_msg_path = File.join(temp_dir, "last.md")
done_path     = File.join(temp_dir, "build.done")
# Clear stale completion files so a reused --session NAME with the same tmp dir
# does not report the previous run as finished before the new one completes.
FileUtils.rm_f([last_msg_path, done_path])
File.write(task_path, prompt)

pane_id = launch_codex_pane(
  session:      session,
  repo_root:    root,
  task_path:    task_path,
  last_msg_path: last_msg_path,
  done_path:    done_path,
  sandbox:      options[:sandbox],
  effort:       options[:effort],
  model:        options[:model]
)

terminal_opened = !options[:no_terminal] &&
                  RUBY_PLATFORM.include?("darwin") &&
                  open_terminal_window(session, root)

print_observation_info(
  session:          session,
  pane_id:          pane_id,
  task_path:        task_path,
  last_msg_path:    last_msg_path,
  done_path:        done_path,
  terminal_opened:  terminal_opened
)
