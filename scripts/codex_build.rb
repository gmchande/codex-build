#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "shellwords"
require "tmpdir"

AUTHORITY_CONTEXT_FILES           = %w[AGENTS.md CLAUDE.md].freeze
REPO_ROOT_AUTHORITY_CONTEXT_FILES = (AUTHORITY_CONTEXT_FILES + %w[.claude/CLAUDE.md]).freeze
MAX_CONTEXT_BYTES                 = 100_000
MAX_CONTEXT_BUNDLE_BYTES          = 240_000
MAX_PLAN_BYTES                    = 200_000
CHECK_PATTERNS                    = [
  /bundle exec rake \w+/,
  /rake (?:check|test)/,
  /npm test/,
  /yarn test/,
  /make test/,
  /pytest/,
  /go test/,
].freeze

options = {
  plan:             nil,
  intent:           nil,
  feedback:         nil,
  check:            nil,
  session:          nil,
  sandbox:          "workspace-write",
  effort:           "high",
  model:            nil,
  explicit_sandbox: false,
  doctor:           false,
  dry_run:          false,
  no_terminal:      false
}

OptionParser.new do |opts|
  opts.banner = "Usage: codex_build.rb [options]"
  opts.on("--plan PATH",    "Plan or PRD file to implement")                                { |v| options[:plan]       = v }
  opts.on("--intent TEXT",  "Short intent string (alternative to --plan)")                  { |v| options[:intent]     = v }
  opts.on("--feedback TEXT", "Send review findings to the most recent Codex session")       { |v| options[:feedback]   = v }
  opts.on("--check CMD",    "Check command to run on completion (auto-detected if omitted)") { |v| options[:check]     = v }
  opts.on("--session NAME", "Zellij session name (default: codex-build-HHMMSS)")            { |v| options[:session]   = v }
  opts.on("--sandbox MODE", "Codex sandbox mode (default: workspace-write)") do |v|
    options[:sandbox] = v
    options[:explicit_sandbox] = true
  end
  opts.on("--effort LEVEL", "Codex reasoning effort (none|minimal|low|medium|high|xhigh; default: high)") do |v|
    options[:effort] = v
  end
  opts.on("--model MODEL",  "Codex model") do |v|
    options[:model] = v
  end
  opts.on("--doctor",       "Check local dependencies and exit")                            {      options[:doctor]      = true }
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

def command_path(name)
  stdout, _stderr, status = run_command("sh", "-c", "command -v #{Shellwords.escape(name)}", allow_failure: true)
  status.success? ? stdout.strip : nil
end

def inside_git_repo?
  _stdout, _stderr, status = run_command("git", "rev-parse", "--is-inside-work-tree", allow_failure: true)
  status.success?
end

def git_ref_exists?(ref)
  _stdout, _stderr, status = run_command("git", "rev-parse", "--verify", "--quiet", ref, allow_failure: true)
  status.success?
end

def head_exists?
  git_ref_exists?("HEAD")
end

def empty_tree_ref
  stdout, _stderr, _status = run_command("git", "hash-object", "-t", "tree", "/dev/null")
  stdout.strip
end

def git_repo_root
  stdout, _stderr, _status = run_command("git", "rev-parse", "--show-toplevel")
  stdout.strip
end

def session_name(options)
  return options[:session] if options[:session]

  prefix = options[:feedback] ? "codex-feedback" : "codex-build"
  "#{prefix}-#{Time.now.strftime("%H%M%S")}"
end

def likely_text_file?(path)
  File.file?(path) && !File.binread(path, 4096).to_s.include?("\x00")
rescue Errno::ENOENT, Errno::EACCES
  false
end

def truncate_text(text, max_bytes, label)
  return [text, false] if text.bytesize <= max_bytes

  truncated = text.byteslice(0, max_bytes).to_s.scrub
  ["#{truncated}\n\n... #{label} truncated at #{max_bytes} bytes ...", true]
end

def project_context_dirs(repo_root)
  dirs = []
  current = File.expand_path(repo_root)
  home = File.expand_path(Dir.home)

  loop do
    dirs << current
    break if current == home || current == "/"

    parent = File.dirname(current)
    break if parent == current

    current = parent
  end

  dirs.reverse
end

def project_context_paths(repo_root)
  seen = {}
  expanded_root = File.expand_path(repo_root)

  project_context_dirs(repo_root).flat_map do |dir|
    names = File.expand_path(dir) == expanded_root ? REPO_ROOT_AUTHORITY_CONTEXT_FILES : AUTHORITY_CONTEXT_FILES
    names.map { |name| File.join(dir, name) }
  end.select do |path|
    if File.file?(path) && !seen[path]
      seen[path] = true
    end
  end
end

def repo_root_authority_paths(repo_root)
  REPO_ROOT_AUTHORITY_CONTEXT_FILES.map { |name| File.join(repo_root, name) }.select { |path| File.file?(path) }
end

def relative_context_path(path, repo_root)
  Pathname.new(path).relative_path_from(Pathname.new(repo_root)).to_s
rescue ArgumentError
  path
end

def project_context_file_section(path, repo_root)
  label = relative_context_path(path, repo_root)

  if !likely_text_file?(path)
    ["### #{label}\n\nSkipped: not a readable text file.\n", false]
  else
    text, truncated = truncate_text(File.read(path), MAX_CONTEXT_BYTES, "project context #{label}")
    notice = truncated ? "Truncated: file exceeded #{MAX_CONTEXT_BYTES} bytes.\n\n" : ""
    ["### #{label}\n\n#{notice}```markdown\n#{text}\n```\n", truncated]
  end
rescue Errno::ENOENT, Errno::EACCES
  ["### #{label}\n\nSkipped: file disappeared or became unreadable.\n", false]
end

def project_context_bundle(repo_root)
  paths = project_context_paths(repo_root)
  return ["", []] if paths.empty?

  sections = []
  truncated = []
  total_bytes = 0

  paths.each do |path|
    section, section_truncated = project_context_file_section(path, repo_root)
    section_bytes = section.bytesize

    if total_bytes + section_bytes > MAX_CONTEXT_BUNDLE_BYTES
      label = relative_context_path(path, repo_root)
      sections << "### #{label}\n\nSkipped: project context bundle exceeded #{MAX_CONTEXT_BUNDLE_BYTES} bytes.\n"
      truncated << label
      break
    end

    total_bytes += section_bytes
    sections << section
    truncated << relative_context_path(path, repo_root) if section_truncated
  end

  [
    <<~TEXT,
      Project context (auto-loaded from authority files; broader ancestor files appear first and closer files override earlier guidance):

      #{sections.join("\n")}
    TEXT
    truncated
  ]
end

def extract_check_command(text)
  # Earliest match in the file wins, not first pattern in the list: a doc that
  # leads with its check command should beat an incidental mention later on.
  CHECK_PATTERNS.map { |pattern| text.match(pattern) }.compact.min_by { |m| m.begin(0) }&.to_s
end

def detect_check_command(repo_root)
  repo_root_authority_paths(repo_root).each do |path|
    next unless likely_text_file?(path)

    command = extract_check_command(File.read(path))
    return command if command
  end

  nil
end

def read_plan(path)
  return nil unless path

  unless File.file?(path)
    warn "Plan file not found: #{path}"
    exit 1
  end

  truncate_text(File.read(path), MAX_PLAN_BYTES, "plan").first
end

def final_message_contract
  <<~XML.chomp
    <final_message>
    Codex's final message must be Markdown with exactly these sections, in this order:
    - Files changed
    - Deviations from the plan — each with why; write "None" explicitly if none
    - Commands run and their results
    - Known gaps / risks
    - Questions needing the user's decision
    </final_message>
  XML
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
  parts << final_message_contract

  "# Codex Build — #{File.basename(repo_root)} / #{session}\n\n" + parts.join("\n\n")
end

def build_feedback_prompt(feedback:, check_cmd:, repo_root:, session:)
  parts = ["<feedback>\n#{feedback.strip}\n</feedback>"]

  check_instruction = if check_cmd
                        "When done, rerun: #{check_cmd}"
                      else
                        "When done, rerun the check command from the original task if one is known."
                      end

  parts << <<~XML.chomp
    <instructions>
    Fix only the findings listed in <feedback>.
    Keep changes tightly scoped.
    Do not revisit or expand other parts of the earlier task.
    #{check_instruction}
    End with the final-message contract in <final_message>.
    </instructions>
  XML

  parts << final_message_contract

  "# Codex Feedback — #{File.basename(repo_root)} / #{session}\n\n" + parts.join("\n\n")
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

def macos_app_available?(name)
  return false unless command_available?("osascript")

  _stdout, _stderr, status = run_command("osascript", "-e", "id of application \"#{name}\"", allow_failure: true)
  status.success?
end

def doctor!
  required_checks = []
  required_checks << ["git", command_available?("git")]
  required_checks << ["ruby", command_available?("ruby")]
  required_checks << ["zellij", command_available?("zellij")]
  required_checks << ["codex", command_available?("codex")]
  required_checks << ["ZELLIJ_SOCKET_DIR", !ENV.fetch("ZELLIJ_SOCKET_DIR", "").empty?]

  optional_checks = []
  optional_checks << ["osascript", command_available?("osascript")]
  optional_checks << ["Ghostty.app", macos_app_available?("Ghostty")]

  required_checks.each do |label, ok|
    puts "#{ok ? "OK" : "MISSING"} #{label}"
  end

  optional_checks.each do |label, ok|
    puts "#{ok ? "OK" : "OPTIONAL_MISSING"} #{label}"
  end

  exit(required_checks.all? { |_label, ok| ok } ? 0 : 1)
end

def setup_temp_dir(session)
  dir = File.join(Dir.tmpdir, "codex-build-#{session}")
  FileUtils.mkdir_p(dir, mode: 0o700)
  FileUtils.chmod(0o700, dir)
  dir
end

def write_private_file(path, content)
  File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write(content)
  end
  FileUtils.chmod(0o600, path)
end

def write_pre_run_snapshot(temp_dir)
  status, _stderr, _status = run_command("git", "status", "--short")
  comparison = head_exists? ? "HEAD" : empty_tree_ref
  diff, _diff_stderr, _diff_status = run_command("git", "diff", "--no-ext-diff", comparison, "--")
  status_path = File.join(temp_dir, "pre.status")
  diff_path = File.join(temp_dir, "pre.diff")

  write_private_file(status_path, status)
  write_private_file(diff_path, diff)

  [status_path, diff_path, !status.strip.empty?]
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

def codex_exec_command(last_msg_path:, sandbox:, effort:, model:)
  codex_cmd = ["codex", "exec", "--sandbox", sandbox, "-o", last_msg_path]
  codex_cmd.push("-c", "model_reasoning_effort=#{effort}") if effort
  codex_cmd.push("-m", model) if model
  codex_cmd.push("-")
  codex_cmd
end

def codex_resume_help(required:)
  unless command_available?("codex")
    if required
      warn "codex not found on PATH."
      exit 1
    end

    return ""
  end

  stdout, stderr, status = run_command("codex", "exec", "resume", "--help", allow_failure: true)
  if !status.success? && required
    warn "Could not inspect supported flags with: codex exec resume --help"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  "#{stdout}\n#{stderr}"
end

def resume_supports_option?(help_text, option)
  case option
  when "--sandbox"
    help_text.include?("--sandbox")
  when "-c"
    help_text.match?(/(?:^|\s)-c(?:,|\s)/)
  when "-m"
    help_text.match?(/(?:^|\s)-m(?:,|\s)/) || help_text.include?("--model")
  else
    false
  end
end

def codex_resume_command(last_msg_path:, sandbox:, explicit_sandbox:, effort:, model:, help_text:)
  codex_cmd = ["codex", "exec", "resume", "--last"]
  codex_cmd.push("--sandbox", sandbox) if explicit_sandbox && resume_supports_option?(help_text, "--sandbox")
  codex_cmd.push("-c", "model_reasoning_effort=#{effort}") if effort && resume_supports_option?(help_text, "-c")
  codex_cmd.push("-m", model) if model && resume_supports_option?(help_text, "-m")
  codex_cmd.push("-o", last_msg_path, "-")
  codex_cmd
end

def codex_shell_command(codex_cmd, task_path, done_path, run_log_path, error_path)
  # The marker is always written and carries codex's exit code, so a failed run
  # (auth error, CLI crash) is distinguishable from success without inspecting
  # the pane. `touch` or `&&` would make failure look like a hung or green run.
  ansi_filter = "ruby -pe '$_.gsub!(/\\e\\[[0-?]*[ -\\/]*[@-~]/, \"\")'"
  codex_inner_cmd = "#{codex_cmd.shelljoin} < #{task_path.shellescape}"
  [
    ["script", "-q", run_log_path, "sh", "-c", codex_inner_cmd].shelljoin,
    "rc=$?",
    "if [ \"$rc\" -ne 0 ]; then tail -n 40 #{run_log_path.shellescape} | #{ansi_filter} > #{error_path.shellescape}; fi",
    "echo $rc > #{done_path.shellescape}",
    "echo",
    "echo Codex build exited with status $rc",
    "exec ${SHELL:-/bin/zsh} -l"
  ].join("; ")
end

def launch_codex_pane(session:, repo_root:, task_path:, done_path:, run_log_path:, error_path:, codex_cmd:, pane_name:)
  shell_cmd = codex_shell_command(codex_cmd, task_path, done_path, run_log_path, error_path)

  _stdout, stderr, status = zellij("attach", "--create-background", session, allow_failure: true)
  unless status.success?
    warn "Failed to create Zellij session '#{session}': #{stderr.strip}"
    exit 1
  end

  stdout, stderr, status = zellij(
    "--session", session,
    "run", "--cwd", repo_root, "--name", pane_name,
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
  zellij("--session", session, "action", "focus-pane-id", pane_id, allow_failure: true)
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

def manual_attach_command(session)
  "zellij attach #{session.shellescape}"
end

def open_terminal_window(session, repo_root)
  return [false, "osascript is missing; attach manually with: #{manual_attach_command(session)}"] unless command_available?("osascript")

  zellij_path = command_path("zellij")
  zsh_path = command_path("zsh")
  unless zellij_path && zsh_path
    return [false, "Could not resolve zellij or zsh on PATH; attach manually with: #{manual_attach_command(session)}"]
  end

  socket_dir  = ENV.fetch("ZELLIJ_SOCKET_DIR", "")
  attach_inner = "export ZELLIJ_SOCKET_DIR=#{socket_dir.shellescape}; " \
                 "#{zellij_path.shellescape} attach #{session.shellescape}; " \
                 "cd #{repo_root.shellescape}; exec #{zsh_path.shellescape} -l"
  attach_cmd  = "#{zsh_path.shellescape} -lc #{Shellwords.escape(attach_inner)}"

  _stdout, stderr, status = Open3.capture3("osascript", stdin_data: ghostty_script(attach_cmd, repo_root))
  return [true, nil] if status.success?

  detail = stderr.strip.empty? ? "" : " (#{stderr.strip})"
  [false, "Could not auto-open Ghostty#{detail}; attach manually with: #{manual_attach_command(session)}"]
end

def print_observation_info(session:, pane_id:, task_path:, last_msg_path:, done_path:, run_log_path:, error_path:, pre_status_path:, pre_diff_path:, dirty_at_launch:, terminal_opened:, terminal_warning:)
  puts "Codex build started in Zellij session: #{session}"
  puts "Zellij pane:  #{pane_id}"
  puts "Task bundle:  #{task_path}"
  puts "Last message: #{last_msg_path}"
  puts "Done marker:  #{done_path}"
  puts "Run log:      #{run_log_path}"
  puts "Pre status:   #{pre_status_path}"
  puts "Pre diff:     #{pre_diff_path}"
  puts

  if dirty_at_launch
    puts "Tree was dirty at launch; compare review findings against the pre-run snapshot before attributing changes to Codex."
    puts
  end

  if terminal_warning
    puts "Warning: #{terminal_warning}"
    puts
  end

  unless terminal_opened
    puts "Attach:"
    puts "  #{manual_attach_command(session)}"
    puts
  end

  puts "Completion check (marker holds codex's exit code):"
  puts "  test -f #{done_path.shellescape} && cat #{done_path.shellescape}"
  puts "  test -f #{done_path.shellescape} && [ \"$(cat #{done_path.shellescape})\" = \"0\" ] && cat #{last_msg_path.shellescape}"
  puts "Failure detail: test -f #{done_path.shellescape} && [ \"$(cat #{done_path.shellescape})\" != \"0\" ] && cat #{error_path.shellescape}"
  puts
  puts "Background watcher (bounded; exits when marker appears):"
  puts "  for i in $(seq 1 360); do test -f #{done_path.shellescape} && break; sleep 5; done; cat #{done_path.shellescape}"
  puts
  puts "Interrupt:"
  puts "  zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id} Esc"
  puts "  zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id} \"Ctrl c\""
  puts
  puts "Observe (viewport only):"
  puts "  zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id}"
  puts
  puts "Follow up in the same Codex session (from this repo root):"
  puts "  ruby #{File.expand_path(__FILE__).shellescape} --feedback \"...\""
  puts "  codex resume --last   # interactive"
  puts
  puts "Cleanup (only when the user says they are done with this run; leave the session open for follow-ups otherwise):"
  puts "  zellij kill-session #{session.shellescape}  # if still attached"
  puts "  zellij delete-session --force #{session.shellescape}"
  puts
  puts "Observation policy: prefer the background watcher in harness-driven clients; otherwise check the done marker after 2-3 minutes and inspect the pane only on request or to diagnose a stall."
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

doctor! if options[:doctor]

if options[:feedback] && (options[:plan] || options[:intent])
  warn "Cannot combine --feedback with --plan or --intent."
  exit 1
end

unless options[:plan] || options[:intent] || options[:feedback]
  warn "Provide --plan PATH, --intent TEXT, or --feedback TEXT."
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

context_paths = project_context_paths(root)
context_text, context_truncated = project_context_bundle(root)
context_text = nil if context_text.empty?
check_cmd    = options[:check] || detect_check_command(root)
plan_text    = options[:feedback] ? nil : read_plan(options[:plan])

prompt = if options[:feedback]
           build_feedback_prompt(
             feedback:  options[:feedback],
             check_cmd: check_cmd,
             repo_root: root,
             session:   session
           )
         else
           build_prompt(
             plan_text:    plan_text,
             intent:       options[:intent],
             context_text: context_text,
             check_cmd:    check_cmd,
             repo_root:    root,
             session:      session
           )
         end

if options[:dry_run]
  puts "Sandbox: #{options[:sandbox]}"
  puts "Effort:  #{options[:effort] || "(codex default)"}"
  puts "Model:   #{options[:model]  || "(codex default)"}"
  puts "Session: #{session}"
  puts "Context: #{context_paths.empty? ? "(none found)" : context_paths.join(", ")}"
  puts "Context truncation: #{context_truncated.empty? ? "(none)" : context_truncated.join(", ")}"
  puts "Check:   #{check_cmd       || "(none)"}"
  puts

  if options[:feedback]
    last_msg_path = File.join(Dir.tmpdir, "codex-build-#{session}", "last.md")
    resume_help = codex_resume_help(required: false)
    codex_cmd = codex_resume_command(
      last_msg_path:    last_msg_path,
      sandbox:          options[:sandbox],
      explicit_sandbox: options[:explicit_sandbox],
      effort:           options[:effort],
      model:            options[:model],
      help_text:        resume_help
    )
    puts "Command: #{codex_cmd.shelljoin}"
    puts
    puts "## Feedback prompt"
  else
    puts "## Prompt bundle"
  end
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
run_log_path  = File.join(temp_dir, "run.log")
error_path    = File.join(temp_dir, "build.error")
# Clear stale completion files so a reused --session NAME with the same tmp dir
# does not report the previous run as finished before the new one completes.
FileUtils.rm_f([last_msg_path, done_path, run_log_path, error_path])
write_private_file(task_path, prompt)
pre_status_path, pre_diff_path, dirty_at_launch = write_pre_run_snapshot(temp_dir)

codex_cmd = if options[:feedback]
              resume_help = codex_resume_help(required: true)
              codex_resume_command(
                last_msg_path:    last_msg_path,
                sandbox:          options[:sandbox],
                explicit_sandbox: options[:explicit_sandbox],
                effort:           options[:effort],
                model:            options[:model],
                help_text:        resume_help
              )
            else
              codex_exec_command(
                last_msg_path: last_msg_path,
                sandbox:       options[:sandbox],
                effort:        options[:effort],
                model:         options[:model]
              )
            end

pane_id = launch_codex_pane(
  session:      session,
  repo_root:    root,
  task_path:    task_path,
  done_path:    done_path,
  run_log_path: run_log_path,
  error_path:   error_path,
  codex_cmd:    codex_cmd,
  pane_name:    options[:feedback] ? "Codex Feedback" : "Codex Build"
)

terminal_opened = false
terminal_warning = nil
if !options[:no_terminal] && RUBY_PLATFORM.include?("darwin")
  terminal_opened, terminal_warning = open_terminal_window(session, root)
elsif !options[:no_terminal]
  terminal_warning = "Auto-open is macOS/Ghostty only; attach manually with: #{manual_attach_command(session)}"
end

print_observation_info(
  session:          session,
  pane_id:          pane_id,
  task_path:        task_path,
  last_msg_path:    last_msg_path,
  done_path:        done_path,
  run_log_path:     run_log_path,
  error_path:       error_path,
  pre_status_path:  pre_status_path,
  pre_diff_path:    pre_diff_path,
  dirty_at_launch:  dirty_at_launch,
  terminal_opened:  terminal_opened,
  terminal_warning: terminal_warning
)
