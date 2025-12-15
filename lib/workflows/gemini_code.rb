# lib/workflows/gemini_code.rb
# Sends task content directly to Gemini and returns the response
# encoding: utf-8

require_relative 'base'
require 'open3'
require 'json'
require 'shellwords'
require 'thread'

# DPSY system imports
require_relative '../task_classifier'
require_relative '../conversation_summarizer'
require_relative '../prompt_templates/simple_query'
require_relative '../prompt_templates/email'
require_relative '../prompt_templates/company_research'
require_relative '../prompt_templates/general'

# GEPA system imports
require_relative '../task_decomposer'

# Force UTF-8 encoding for all string operations
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module Workflows
  class GeminiCode < Base
    def execute
      log_info("Executing AI workflow for task: #{task.name}")

      require 'timeout'

      # Workflow-level timeout : 30 minutes max for entire workflow
      # This prevents runaway multi-step GEPA workflows from hanging forever
      begin
        Timeout.timeout(1800) do
          # GEPA: Check if task should be decomposed into steps
          if TaskDecomposer.should_decompose?(task, @comment_text)
            log_info("GEPA: Task requires decomposition - using multi-step execution")
            return execute_with_gepa
          end

          # Single-step execution (original behavior)
          execute_single_step
        end
      rescue Timeout::Error
        log_error("Workflow timed out after 30 minutes")
        {
          success: false,
          error: "Workflow timeout after 30 minutes",
          comment: "❌ Workflow timed out after 30 minutes. Task may be too complex or stuck."
        }
      end
    rescue => e
      log_error("Unexpected error in AI workflow: #{e.class}: #{e.message}")
      log_error(e.backtrace.first(5).join("\n"))
      {
        success: false,
        error: e.message,
        comment: "❌ Error: #{e.message}"
      }
    end

    def execute_single_step
      # Build prompt from task content
      prompt = build_prompt

      primary_ai = ENV['ASANA_MONITOR_CLAUDE_FIRST'] == 'true' ? 'Claude' : 'Gemini'
      log_info("Sending prompt to #{primary_ai} (primary) (#{prompt.length} chars)")

      # Send to Gemini first, fallback to Claude if needed
      response = execute_with_fallback(prompt)

      if response[:success]
        provider_name = response[:provider] == :claude ? "Claude" : "Gemini"
        log_info("#{provider_name} responded successfully (#{response[:output].length} chars)")
        {
          success: true,
          comment: format_response(response[:output], response[:provider])
        }
      else
        log_error("AI workflow failed: #{response[:error]}")
        {
          success: false,
          error: response[:error],
          comment: "❌ AI error: #{response[:error]}"
        }
      end
    end

    def execute_with_gepa
      steps = TaskDecomposer.decompose(task, @comment_text)

      log_info("GEPA: Task decomposed into #{steps.size} step(s)")
      log_info("GEPA: Using sequential execution")

      execute_steps_sequential(steps)
    end

    def execute_steps_sequential(steps)
      # Original sequential implementation (fallback)
      results = []
      successful_steps = 0

      steps.each do |step|
        log_info("GEPA: Executing step #{step.number}/#{steps.size} : #{step.name}")
        add_progress_comment("🔄 Step #{step.number}/#{steps.size} : #{step.name}")

        # Execute with retry
        result = execute_step_with_retry(step)
        results << result

        if result[:success]
          successful_steps += 1
          summary = extract_summary(result[:output])
          log_info("GEPA: Step #{step.number} succeeded : #{summary}")
          add_progress_comment("✅ Step #{step.number} : #{summary}")
        else
          log_error("GEPA: Step #{step.number} failed : #{result[:error]}")
          add_progress_comment("❌ Step #{step.number} failed : #{result[:error]}")
        end
      end

      # Generate final summary
      {
        success: successful_steps > 0,
        comment: build_final_summary(steps.size, successful_steps, results)
      }
    end

    def execute_step_with_retry(step)
      # Execute step with optional retry logic & timeout protection
      require 'timeout'

      result = nil
      begin
        # Per-step timeout : 10 minutes max (includes retries)
        Timeout.timeout(600) do
          result = execute_step(step)

          # Retry if step failed & retry is enabled
          if !result[:success] && step.retry_on_failure
            log_info("GEPA: Retrying step #{step.number} (1 retry attempt)")
            result = execute_step(step)

            if result[:success]
              log_info("GEPA: Step #{step.number} succeeded on retry")
            else
              log_error("GEPA: Step #{step.number} failed after retry")
            end
          end
        end
      rescue Timeout::Error
        log_error("GEPA: Step #{step.number} timed out after 600 seconds")
        result = {
          success: false,
          error: "Step timeout after 10 minutes"
        }
      end

      result
    end

    def execute_step(step)
      # Build a focused prompt for this specific step
      prompt = build_step_prompt(step)

      # Send to Gemini/Claude
      response = execute_with_fallback(prompt)

      if response[:success]
        {
          success: true,
          output: response[:output],
          provider: response[:provider]
        }
      else
        {
          success: false,
          error: response[:error]
        }
      end
    end

    def build_step_prompt(step)
      # Build a focused prompt for a single step
      parts = []
      parts << "Task Context : #{task.name}" if task.name && !task.name.strip.empty?
      parts << "\n\nOverall Goal : #{task.notes}" if task.notes && !task.notes.strip.empty?
      parts << "\n\nCurrent Step (#{step.number}) : #{step.description}"
      parts << "\n\nSuccess Criteria : #{step.success_criteria}"

      # Add relevant API instructions based on step content
      if step.description.downcase.include?("market map")
        parts << "\n\n" + market_map_instructions
      elsif step.description.downcase.include?("research") || step.description.downcase.include?("attio")
        parts << "\n\n" + company_research_instructions
      elsif step.description.downcase.include?("email")
        parts << "\n\n" + email_instructions
      end

      parts.join.strip
    end

    def company_research_instructions
      <<~INSTRUCTIONS
      COMPANY RESEARCH APIs (REQUIRED):

      CRITICAL: When asked to ADD or CREATE companies in Attio, you MUST actually execute the API calls.
      Don't just describe what should be done - DO IT by running the code.

      Available APIs:
         - AttioAPI.find_or_create(domain: 'startup.com', name: 'Startup Inc', source: 'referral')
           → Use this to ADD companies to Attio (required for "add to attio" tasks)
         - AttioAPI.find(domain: 'acme.com', format: :detailed)
           → Use this to CHECK if company exists before creating
         - ResearchAPI.vcbench_analyze(domain: 'acme.com')
         - ResearchAPI.harmonic_company(domain: 'acme.com', format: :table)

      To execute these APIs, use Ruby directly:
         ruby -e "require_relative '/Users/tomasztunguz/.gemini/code_mode/attio_api'; puts AttioAPI.find_or_create(domain: 'startup.com', name: 'Startup', source: 'referral').to_json"

      Or use the execute script:
         echo "AttioAPI.find_or_create(domain: 'startup.com', name: 'Startup', source: 'referral')" | ruby /Users/tomasztunguz/.gemini/code_mode/execute.rb

      Your response MUST include:
         1. The actual commands you executed
         2. The results from each API call
         3. Confirmation that companies were added (with Attio company IDs)
      INSTRUCTIONS
    end

    def email_instructions
      <<~INSTRUCTIONS
      EMAIL API:
         - EmailAPI.search(from: 'sender@domain.com', limit: 3, format: :concise)
         - EmailAPI.send(to: 'recipient@domain.com', subject: '...', body: '...')

         Usage: require_relative '/Users/tomasztunguz/.gemini/code_mode/email_api'
      
      OUTPUT REQUIREMENT:
         - If you draft or send an email, you MUST include the full text of the email (Subject, To, Body) in your response.
         - Do NOT just say 'I drafted the email'. Show the draft so the user can review it.
      INSTRUCTIONS
    end

    def market_map_instructions
      <<~INSTRUCTIONS
      MARKET MAP APIs:
         - MarketMapAPI.generate(domains: ['stripe.com', 'plaid.com'], skip_forum: true)
           Generates a new market map analysis with company research, growth metrics, AI summary
         - MarketMapAPI.quick('acme.com')
           Quick single-domain market map generation

         - NotionAPI.create_market_map_page(title: 'Market Map Name', companies: [...])
           Creates a new market map page in Notion with the generated content
         - AttioAPI.create_market_map(name: 'Market Map Name', domains: ['acme.com', 'startup.com'])
           Creates a market map record in Attio CRM

         For NEW market maps:
         1. Use MarketMapAPI.generate() to create full analysis
         2. Save the content to clipboard or file
         3. Create companies in Attio if needed with AttioAPI.find_or_create()

         For ADDING to EXISTING market maps:
         CRITICAL: You MUST have access to Theory MCP tools. Check your available tools for:
           - mcp__theorymcp__search_market_maps_by_name
           - mcp__theorymcp__add_company_to_market_map
           - mcp__theorymcp__update_market_map_content
           - mcp__theorymcp__get_attio_market_map_by_id (for verification)

         WORKFLOW WITH VERIFICATION:
         1. Search for the market map:
            mcp__theorymcp__search_market_maps_by_name(market_map_name: "AI Sales")
            → Save the market_map_id and note_link from the response

         2. Verify company exists in Attio:
            mcp__theorymcp__get_company_by_name(company_name: "Bespoke Labs")
            → Confirm company is in Attio before adding to market map

         3. Add company to market map:
            mcp__theorymcp__add_company_to_market_map(
              market_map_notion_link: "[full Notion URL from step 1]",
              new_company_domains: ["domain.com"]
            )
            → This triggers background processing (linking + analysis)

         4. VERIFICATION REQUIRED: After 30 seconds, re-fetch the market map to confirm:
            mcp__theorymcp__get_attio_market_map_by_id(market_map_id: "[ID from step 1]")
            → Check that the Notion markdown content now includes the new company
            → If company is NOT in the markdown, report FAILURE with error details

         IMPORTANT VERIFICATION STEPS:
         - ALWAYS wait 30 seconds after add_company_to_market_map before verification
         - Check the "market_map_notes_markdown" field for company name or domain
         - If verification fails, investigate : Check Attio UI, Notion page, and background job logs
         - Report detailed error if company wasn't added (don't just say "processing in background")

         If MCP tools are truly unavailable, report this as an ERROR - the configuration is broken.

         Usage:
           require_relative '/Users/tomasztunguz/.gemini/code_mode/market_map_api'
           require_relative '/Users/tomasztunguz/.gemini/code_mode/notion_api'
           require_relative '/Users/tomasztunguz/.gemini/code_mode/attio_api'
      INSTRUCTIONS
    end

    def add_progress_comment(text)
      # Add progress update to Asana task
      # We use TaskAPI directly here to ensure progress is visible
      log_info("Progress: #{text}")
      
      begin
        TaskAPI.add_comment(task_id: task.gid, comment: text)
      rescue => e
        log_error("Failed to post progress comment: #{e.message}")
      end
    end

    def extract_summary(output)
      # Extract first meaningful line or first 100 chars
      lines = output.split("\n").reject { |l| l.strip.empty? }
      first_line = lines.first || ""
      first_line.strip[0..100]
    end

    def build_final_summary(total_steps, successful_steps, results)
      summary = "🤖 GEPA Multi-Step Execution:\n\n"
      summary += "Completed #{successful_steps}/#{total_steps} steps successfully.\n\n"

      if successful_steps == total_steps
        summary += "✅ All steps completed!\n\n"
      elsif successful_steps > 0
        summary += "⚠️ Partial completion.\n\n"
      else
        summary += "❌ No steps completed successfully.\n\n"
      end

      # Include full step results (especially email drafts)
      results.each_with_index do |result, index|
        step_num = index + 1
        if result[:success]
          # DON'T strip markdown from outputs - preserve formatting (especially for emails)
          # Just clean up excessive whitespace
          clean_output = result[:output].strip

          # For email-related steps, preserve the full draft
          # Check for email indicators more broadly
          is_email = clean_output.match?(/(Subject:|To:|From:|Cc:|Bcc:|Dear |Hi |Hello |Sincerely|Best regards|Thanks)\b/i) ||
                     clean_output.match?(/(email|draft|send|reply)\b/i) ||
                     clean_output.include?('@')

          # Truncate very long non-email outputs (>5000 chars to allow for long emails)
          if !is_email && clean_output.length > 5000
            clean_output = clean_output[0..5000] + "\n\n...(truncated, #{clean_output.length} chars total)"
          end

          # Add clear section header for email drafts
          if is_email && clean_output.match?(/(draft|email)\b/i)
            summary += "━━━ Step #{step_num} : Email Draft ━━━\n#{clean_output}\n\n"
          else
            summary += "━━━ Step #{step_num} Result ━━━\n#{clean_output}\n\n"
          end
        else
          summary += "━━━ Step #{step_num} Failed ━━━\nError : #{result[:error]}\n\n"
        end
      end

      summary
    end

    private

    def build_prompt
      # DPSY: Dynamic Prompt System - select template based on task type
      @task_type = TaskClassifier.classify(task, @comment_text)

      log_info("DPSY: Task classified as :#{@task_type}")

      # Summarize long conversation histories to save tokens
      summarized_comments = ConversationSummarizer.summarize_if_needed(all_comments)

      if summarized_comments && all_comments && summarized_comments.size < all_comments.size
        log_info("DPSY: Conversation history summarized (#{all_comments.size} → #{summarized_comments.size} comments)")
      end

      # Select appropriate template based on task type
      template_class = case @task_type
      when :simple_query      then PromptTemplates::SimpleQuery
      when :email             then PromptTemplates::Email
      when :company_research  then PromptTemplates::CompanyResearch
      else                         PromptTemplates::General
      end

      log_info("DPSY: Using #{template_class.name}")

      # Build prompt using selected template
      template = template_class.new(
        task: task,
        comments: summarized_comments,
        comment_text: @comment_text,
        from_comment: from_comment?
      )

      prompt = template.build

      # Validate prompt has meaningful content
      if prompt.strip.empty?
        diagnostics = []
        diagnostics << "task.name: #{task.name.inspect}" if task.respond_to?(:name)
        diagnostics << "task.notes: #{task.notes.inspect}" if task.respond_to?(:notes)
        diagnostics << "comments: #{all_comments&.size || 0}"
        diagnostics << "comment_text: #{@comment_text.inspect}" if @comment_text

        raise "Cannot build prompt - no content available. #{diagnostics.join(', ')}"
      end

      log_info("DPSY: Prompt built (#{prompt.length} chars)")

      prompt
    end

    def execute_with_fallback(prompt)
      # Dec 2025 : Gemini CLI nightly (0.21.0+) now supports MCP tools correctly
      # MCP timeout issue has been fixed - Gemini can now handle theorymcp calls
      # Set ASANA_MONITOR_CLAUDE_FIRST=true to override and use Claude first
      use_claude_first = ENV['ASANA_MONITOR_CLAUDE_FIRST'] == 'true'

      if use_claude_first
        # Claude-first mode (optional override)
        claude_result = send_to_claude_raw(prompt)

        if claude_result[:success]
          log_info("✅ Claude (primary) succeeded")
          return claude_result
        end

        log_info("Claude failed (#{claude_result[:error]}). Trying Gemini fallback...")

        # Fallback to Gemini
        gemini_result = send_to_gemini_raw(prompt)

        if gemini_result[:success]
          log_info("✅ Gemini fallback succeeded")
          return gemini_result
        end

        log_error("❌ Both Claude & Gemini failed")
        {
          success: false,
          error: "Claude failed: #{claude_result[:error]}. Gemini fallback also failed: #{gemini_result[:error]}"
        }
      else
        # Gemini-first mode (DEFAULT)
        # MCP tools now work with Gemini CLI nightly builds
        gemini_result = send_to_gemini_raw(prompt)

        if gemini_result[:success]
          log_info("✅ Gemini succeeded")
          return gemini_result
        end

        log_info("Gemini failed (#{gemini_result[:error]}). Falling back to Claude...")

        # Fallback to Claude
        claude_result = send_to_claude_raw(prompt)

        if claude_result[:success]
          log_info("✅ Claude fallback succeeded")
          return claude_result
        end

        log_error("❌ Both Gemini & Claude failed")
        {
          success: false,
          error: "Gemini failed: #{gemini_result[:error]}. Claude fallback also failed: #{claude_result[:error]}"
        }
      end
    end

    def send_to_gemini_raw(prompt)
      begin
        safe_prompt = prompt.force_encoding('UTF-8').scrub('')

        # Use the Gemini CLI
        # Known issue: Gemini CLI hangs waiting for stdin in non-TTY environments (GitHub issue #6715)
        # Fix: Use echo with pipe to provide input and immediately close stdin
        # We use --approval-mode yolo to automatically execute actions without confirmation (since this is a daemon)

        # Alternative approach: Use echo to provide input
        require 'tempfile'
        require 'shellwords'

        # Create temp file for prompt to avoid shell escaping issues
        prompt_file = Tempfile.new(['gemini_prompt', '.txt'])
        prompt_file.write(safe_prompt)
        prompt_file.close

        # Use cat with pipe to avoid stdin hang issue
        # Using 'gemini' from PATH (npm installed) instead of hardcoded path
        cmd = "cat #{prompt_file.path} | gemini --model gemini-3-pro-preview --approval-mode yolo --debug"

        log_info("Executing Gemini with pipe workaround")

        output = ""
        error = ""
        exit_status = nil

        require 'timeout'
        begin
          Timeout.timeout(300) do  # 5 minutes max per execution
            # Use system shell to execute with proper pipe
            output, error, status = Open3.capture3("/bin/sh", "-c", cmd)
            exit_status = status
          end
        rescue Timeout::Error
          log_error("Gemini timed out after 300 seconds")
          return { success: false, error: "Gemini timeout after 300 seconds" }
        ensure
          # Clean up temp file
          prompt_file.unlink if prompt_file
        end

        if exit_status && exit_status.success?
          {
            success: true,
            output: output.force_encoding('UTF-8').scrub('').strip,
            provider: :gemini
          }
        else
          error_msg = error.force_encoding('UTF-8').scrub('').strip
          clean_error = clean_error_message(error_msg)

          {
            success: false,
            error: "Gemini failed: #{clean_error}"
          }
        end
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
        {
          success: false,
          error: "Encoding error: #{e.message}"
        }
      rescue => e
        {
          success: false,
          error: "#{e.class}: #{e.message}"
        }
      end
    end

    def send_to_claude_raw(prompt)
      begin
        # Use Claude Code CLI with -p (print) flag
        # Using the correct model name: claude-sonnet-4-5-20250929 (note: hyphens, not dots)
        # --dangerously-skip-permissions: Bypass all permission checks (daemon mode)
        
        # IMPORTANT: Unset ANTHROPIC_API_KEY to force Claude CLI to use Max subscription OAuth
        # credentials from ~/.claude/.credentials.json instead of API key
        ENV.delete('ANTHROPIC_API_KEY')

        # Dynamically find Claude binary (supports multiple machines/environments)
        claude_path = find_claude_binary
        unless claude_path
          return {
            success: false,
            error: "Claude binary not found in PATH or common locations"
          }
        end

        cmd = "#{claude_path} -p --model claude-sonnet-4-5-20250929 --dangerously-skip-permissions --mcp-config /Users/tomasztunguz/.asana-monitor-mcp.json"

        log_info("Executing Claude (using Max subscription OAuth + MCP servers): #{cmd}")

        output = ""
        error = ""
        exit_status = nil
        pid = nil

        require 'timeout'
        begin
          Timeout.timeout(600) do  # 10 minutes max per execution
            Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
              pid = wait_thr.pid

              # Write prompt to stdin
              stdin.write(prompt)
              stdin.close

              # Read output
              output = stdout.read
              error = stderr.read
              exit_status = wait_thr.value
            end
          end
        rescue Timeout::Error
          log_error("Claude timed out after 600 seconds. Killing process #{pid}...")
          if pid
            begin
              Process.kill("KILL", pid)
              Process.detach(pid)
            rescue Errno::ESRCH
              # Process already dead
            end
          end
          return { success: false, error: "Claude timeout after 600 seconds" }
        end

        if exit_status && exit_status.success?
          {
            success: true,
            output: output.force_encoding('UTF-8').scrub('').strip,
            provider: :claude
          }
        else
          error_msg = error.force_encoding('UTF-8').scrub('').strip

          # Log additional debug info for empty errors
          if error_msg.empty?
            log_error("Claude failed with exit code #{exit_status.exitstatus} but no error message. stdout length: #{output.length}")
          end

          {
            success: false,
            error: "Claude failed: #{error_msg}"
          }
        end
      rescue => e
        {
          success: false,
          error: "Claude error: #{e.message}"
        }
      end
    end

    def find_claude_binary
      # Try to find Claude binary across different machines and installation methods

      # 1. Check if 'claude' is in PATH (most reliable)
      claude_in_path = `which claude 2>/dev/null`.strip
      return claude_in_path if !claude_in_path.empty? && File.executable?(claude_in_path)

      # 2. Check common installation locations
      common_paths = [
        '/opt/homebrew/bin/claude',                    # Homebrew on Apple Silicon
        '/usr/local/bin/claude',                       # Homebrew on Intel Mac
        "#{ENV['HOME']}/Library/pnpm/claude",          # pnpm global install
        "#{ENV['HOME']}/.local/bin/claude",            # Local bin
        "#{ENV['HOME']}/bin/claude"
      ]

      common_paths.each do |path|
        return path if File.exist?(path) && File.executable?(path)
      end

      # 3. Not found
      nil
    end

    def clean_error_message(error_msg)
      # Remove filesystem warning lines (WARN about /Library/Trial, /dev/fd, etc.)
      lines = error_msg.split("\n")
      cleaned_lines = lines.reject do |line|
        line.include?("[WARN] Skipping unreadable directory") ||
        line.include?("EPERM: operation not permitted") ||
        line.include?("EBADF: bad file descriptor") ||
        line.include?("YOLO mode is enabled")
      end

      # Return cleaned message, or original if everything was filtered out
      cleaned = cleaned_lines.join("\n").strip
      cleaned.empty? ? error_msg : cleaned
    end

    def strip_markdown(text)
      # Remove markdown formatting for plain text Asana comments
      result = text.dup

      # Remove code blocks (```...```)
      result.gsub!(/```[a-z]*\n(.*?)\n```/m, '\1')

      # Remove inline code (`...`)
      result.gsub!(/`([^`]+)`/, '\1')

      # Remove bold (**...**)
      result.gsub!(/\*\*([^*]+)\*\*/, '\1')

      # Remove italic (*...*)
      result.gsub!(/\*([^*]+)\*/, '\1')

      # Remove headers (# ... or ## ...)
      result.gsub!(/^[#]{1,6}\s+(.+)$/, '\1')

      # Remove links ([text](url) -> text)
      result.gsub!(/!\[([^\]]+)\]\([^)]+\)/, '\1')

      # Remove HTML tags
      result.gsub!(/<[^>]+>/, '')

      result
    end

    def format_response(output, provider = :gemini)
      # Add a header to identify the provider
      name = provider == :claude ? "Claude" : "Gemini"
      # Strip markdown formatting for plain text
      plain_output = strip_markdown(output)
      "🤖 #{name} Code Response:\n\n#{plain_output}"
    end
  end
end