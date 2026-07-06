# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "fileutils"
require "tmpdir"

class CodexBuildTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/codex_build.rb", __dir__)

  def test_injects_agents_md_and_detects_check_command
    with_repo do |repo|
      File.write(File.join(repo, "AGENTS.md"), <<~MD)
        # Project

        Run checks with `bundle exec rake check`.

        House rule: no guard clauses.
      MD

      stdout = dry_run(repo, "--intent", "do the thing")

      assert_includes stdout, "Check:   bundle exec rake check"
      assert_includes stdout, "<project_context>"
      assert_includes stdout, "House rule: no guard clauses."
      assert_includes stdout, "<verification>\nWhen done, run: bundle exec rake check"
    end
  end

  def test_earliest_check_command_in_file_wins_over_pattern_priority
    with_repo do |repo|
      File.write(File.join(repo, "AGENTS.md"), <<~MD)
        Run `rake test` before anything.

        Historical note: `bundle exec rake build` used to do the heavy lifting.
      MD

      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, "Check:   rake test"
      refute_includes stdout, "bundle exec rake build\n</verification>"
    end
  end

  def test_falls_back_to_claude_md_when_no_agents_md
    with_repo do |repo|
      File.write(File.join(repo, "CLAUDE.md"), "Claude context here. Run npm test.")

      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, "CLAUDE.md"
      assert_includes stdout, "Claude context here."
      assert_includes stdout, "Check:   npm test"
    end
  end

  def test_uses_repo_root_dot_claude_claude_md
    with_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, ".claude"))
      File.write(File.join(repo, ".claude", "CLAUDE.md"), "Nested Claude context here. Run make test.")

      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, ".claude/CLAUDE.md"
      assert_includes stdout, "Nested Claude context here."
      assert_includes stdout, "Check:   make test"
    end
  end

  def test_ignores_ancestor_dot_claude_claude_md
    with_repo do |repo, parent|
      FileUtils.mkdir_p(File.join(parent, ".claude"))
      File.write(File.join(parent, ".claude", "CLAUDE.md"), "Ancestor nested Claude. Run make test.")

      stdout = dry_run(repo, "--intent", "x")

      refute_includes stdout, "Ancestor nested Claude."
      assert_includes stdout, "Check:   (none)"
    end
  end

  def test_ancestor_bundle_orders_parent_before_repo_root
    with_repo do |repo, parent|
      File.write(File.join(parent, "AGENTS.md"), "Parent authority.")
      File.write(File.join(repo, "AGENTS.md"), "Repo authority.")

      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, "Project context (auto-loaded from authority files"
      assert_operator stdout.index("Parent authority."), :<, stdout.index("Repo authority.")
    end
  end

  def test_check_detection_ignores_ancestor_authority_files
    with_repo do |repo, parent|
      File.write(File.join(parent, "AGENTS.md"), "Parent says run rake test.")

      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, "Check:   (none)"
      refute_includes stdout, "<verification>"
    end
  end

  def test_omits_context_and_verification_blocks_when_nothing_found
    with_repo do |repo|
      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, "Context: (none found)"
      assert_includes stdout, "Check:   (none)"
      refute_includes stdout, "<project_context>"
      refute_includes stdout, "<verification>"
    end
  end

  def test_check_flag_overrides_detection
    with_repo do |repo|
      File.write(File.join(repo, "AGENTS.md"), "Run checks with `bundle exec rake check`.")

      stdout = dry_run(repo, "--intent", "x", "--check", "make smoke")

      assert_includes stdout, "Check:   make smoke"
      assert_includes stdout, "When done, run: make smoke"
    end
  end

  def test_plan_content_lands_in_task_block
    with_repo do |repo|
      File.write(File.join(repo, "plan.md"), "# Plan\n\nBuild the widget.")

      stdout = dry_run(repo, "--plan", "plan.md")

      assert_includes stdout, "<task>\n# Plan\n\nBuild the widget.\n</task>"
    end
  end

  def test_final_message_contract_lands_in_prompt
    with_repo do |repo|
      stdout = dry_run(repo, "--intent", "x")

      assert_includes stdout, "<final_message>"
      assert_includes stdout, "Files changed"
      assert_includes stdout, "Deviations from the plan"
      assert_includes stdout, "Commands run and their results"
      assert_includes stdout, "Known gaps / risks"
      assert_includes stdout, "Questions needing the user's decision"
    end
  end

  def test_feedback_dry_run_prints_resume_command_and_prompt
    with_repo do |repo|
      stdout = dry_run(repo, "--feedback", "Fix the missing assertion.")

      assert_includes stdout, "Command: codex exec resume --last"
      assert_includes stdout, "<feedback>\nFix the missing assertion.\n</feedback>"
      assert_includes stdout, "## Feedback prompt"
      refute_includes stdout, "<project_context>"
    end
  end

  def test_feedback_refuses_plan_or_intent
    with_repo do |repo|
      File.write(File.join(repo, "plan.md"), "Plan.")

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--feedback", "fix", "--plan", "plan.md", "--dry-run", chdir: repo
      )

      refute status.success?
      assert_includes stderr, "Cannot combine --feedback with --plan or --intent"

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--feedback", "fix", "--intent", "x", "--dry-run", chdir: repo
      )

      refute status.success?
      assert_includes stderr, "Cannot combine --feedback with --plan or --intent"
    end
  end

  def test_model_and_effort_flags_appear_and_feedback_defaults_to_session_settings
    with_repo do |repo|
      stdout = dry_run(repo, "--intent", "x", "--effort", "low", "--model", "flag-model")

      assert_includes stdout, "Effort:  low"
      assert_includes stdout, "Model:   flag-model"

      stdout = dry_run(repo, "--feedback", "fix")

      assert_includes stdout, "Effort:  (session settings)"
      assert_includes stdout, "Model:   (session settings)"
    end
  end

  def test_relative_plan_path_resolves_from_invoking_subdirectory
    with_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "docs"))
      FileUtils.mkdir_p(File.join(repo, "sub"))
      File.write(File.join(repo, "docs", "plan.md"), "Subdir plan.")

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--plan", "../docs/plan.md", "--dry-run",
        chdir: File.join(repo, "sub")
      )

      assert status.success?, stderr
      assert_includes stdout, "Subdir plan."
    end
  end

  def test_requires_plan_or_intent
    with_repo do |repo|
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--dry-run", chdir: repo
      )

      refute status.success?
      assert_includes stderr, "--plan PATH, --intent TEXT, or --feedback TEXT"
    end
  end

  def test_refuses_to_run_outside_a_git_repo
    Dir.mktmpdir("codex-build-nogit") do |dir|
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--intent", "x", "--dry-run", chdir: dir
      )

      refute status.success?
      assert_includes stderr, "Not inside a git repository"
    end
  end

  private
    def with_repo(&block)
      Dir.mktmpdir("codex-build-test") do |parent|
        repo = File.join(parent, "repo")
        FileUtils.mkdir_p(repo)
        _stdout, _stderr, status = Open3.capture3("git", "init", "-q", repo)
        raise "git init failed" unless status.success?

        block.call(repo, parent)
      end
    end

    def dry_run(repo, *args)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, *args, "--dry-run", chdir: repo
      )
      raise "dry-run failed: #{stderr}" unless status.success?

      stdout
    end
end
