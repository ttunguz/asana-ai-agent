require 'ostruct'
require 'set'
require 'thread'
require 'timeout'
require_relative '../config/agent_config'
require_relative 'workflow_router'
require_relative 'comment_tracker'
require_relative 'llm/robust_client'
require '/Users/tomasztunguz/.gemini/code_mode/task_api'

class AgentMonitor
  LOCK_FILE = '/tmp/agent_monitor.lock'

  def self.run
    # Open the lockfile (create if missing)
    File.open(LOCK_FILE, File::RDWR | File::CREAT, 0644) do |f|
      # Try to acquire an exclusive lock (non-blocking)
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        existing_pid = f.read.strip rescue 'unknown'
        puts "[#{Time.now}] Previous run still in progress (PID: #{existing_pid}), skipping cycle..."
        return
      end

      # We have the lock. Update the PID in the file.
      f.rewind
      f.write(Process.pid)
      f.flush
      f.truncate(f.pos) # Ensure no stale data remains if new PID is shorter

      begin
        new.run
      rescue => e
        # Catch unexpected errors during initialization or run to ensure logging
        # (Though instance.run has its own error handling, this catches instantiation errors)
        puts "[#{Time.now}] [ERROR] Critical failure in AgentMonitor: #{e.message}"
        e.backtrace.each { |line| puts line }
      end
    end
    # Lock is automatically released when the file is closed at the end of the block
  end

  def initialize
    # Load environment variables from .asana-monitor-env if present
    load_env_secrets

    # Ensure API key is available from keychain if not in ENV
    unless ENV['ASANA_API_KEY']
      begin
        require '/Users/tomasztunguz/.gemini/custom_tools_src/secret_manager'
        if key = SecretManager.get('ASANA_API_KEY')
          ENV['ASANA_API_KEY'] = key
          puts "[#{Time.now}] Loaded ASANA_API_KEY from keychain"
        else
          puts "[#{Time.now}] [WARNING] ASANA_API_KEY not found in ENV or keychain"
        end
      rescue LoadError
        puts "[#{Time.now}] [WARNING] Could not load SecretManager to fetch API key"
      end
    end

    @project_gids = AgentConfig::ASANA_PROJECT_GIDS
    @router = WorkflowRouter.new(self)
    @tracker = CommentTracker.new(AgentConfig::COMMENT_STATE_FILE)
    @llm_client = LLM::RobustClient.new
    @log_mutex = Mutex.new

    log "AgentMonitor initialized (projects: #{@project_gids.join(', ')})"
    log "Comment monitoring: #{AgentConfig::ENABLE_COMMENT_MONITORING ? 'enabled' : 'disabled'}"
    log "Max concurrent workers: #{AgentConfig::MAX_CONCURRENT_WORKERS}"
  end

  def run
    log "Starting agent monitor run..."

    # Phase 1: Process new incomplete tasks
    tasks = fetch_incomplete_tasks
    log "Found #{tasks.size} incomplete tasks"

    if tasks.any?
      process_in_parallel(tasks) do |task|
        process_task(task)
      end
    end

    # Phase 2: Monitor existing tasks for comments (if enabled)
    if AgentConfig::ENABLE_COMMENT_MONITORING
      monitored_tasks = fetch_monitored_tasks
      log "Monitoring #{monitored_tasks.size} tasks for new comments"

      if monitored_tasks.any?
        process_in_parallel(monitored_tasks) do |task|
          process_task_comments(task)
        end
      end
    end

    log "Agent monitor run complete"
  rescue => e
    log "ERROR: #{e.class}: #{e.message}", :error
    log e.backtrace.join("\n"), :error
  end

  # Public method - needed by WorkflowRouter to get comment history
  def fetch_task_comments(task_gid)
    # Fetch stories (comments) for a specific task
    url = "https://app.asana.com/api/1.0/tasks/#{task_gid}/stories?opt_fields=gid,text,created_at,created_by.name,type"
    response = execute_asana_request(url)

    return [] unless response && response.code == '200'

    begin
      body = response.body.force_encoding('UTF-8')
      data = JSON.parse(body, symbolize_names: true)
      # Filter for comment type only (exclude system stories)
      comments = data[:data].select { |story| story[:type] == 'comment' }
      comments.map do |comment|
        {
          gid: comment[:gid],
          text: (comment[:text] || '').force_encoding('UTF-8'),
          created_at: comment[:created_at],
          created_by: (comment.dig(:created_by, :name) || '').force_encoding('UTF-8')
        }
      end
    rescue => e
      log "Error parsing comments for task #{task_gid}: #{e.message}", :error
      []
    end
  end

  private

  def process_in_parallel(items, &block)
    queue = Queue.new
    items.each { |item| queue << item }

    workers = (1..AgentConfig::MAX_CONCURRENT_WORKERS).map do
      Thread.new do
        loop do
          begin
            item = queue.pop(true)
          rescue ThreadError
            break
          end

          begin
            Timeout.timeout(AgentConfig::TASK_TIMEOUT) do
              block.call(item)
            end
          rescue => e
            log "Worker thread error: #{e.message}", :error
            log e.backtrace.first(5).join("\n"), :error
          end
        end
      end
    end

    workers.each(&:join)
  end

  def execute_asana_request(url_string, max_retries: 3)
    require 'net/http'
    require 'json'
    require 'uri'

    url = URI(url_string)
    retries = 0

    begin
      request = Net::HTTP::Get.new(url)
      request["Authorization"] = "Bearer #{ENV['ASANA_API_KEY']}"
      request["Accept"] = "application/json"

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE, open_timeout: 10, read_timeout: 30) do |http|
        http.request(request)
      end

      # Handle Rate Limiting (429)
      if response.code == '429'
        retry_after = response['Retry-After']&.to_i || 60
        log "API Rate Limit (429). Waiting #{retry_after} seconds..."
        sleep(retry_after)
        raise "Rate Limit 429"
      end

      # Handle Server Errors (5xx)
      if response.code.start_with?('5')
        raise "Server Error #{response.code}"
      end

      response

    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError => e
      retries += 1
      if retries <= max_retries
        sleep_time = 2 ** retries
        log "Network Error (#{e.class}: #{e.message}). Retrying in #{sleep_time}s..."
        sleep(sleep_time)
        retry
      else
        log "API request failed after #{max_retries} retries: #{e.message}", :error
        nil
      end
    rescue => e
      # For other errors (like 429/500 raised above), we also retry
      retries += 1
      if retries <= max_retries
        sleep_time = 2 ** retries
        log "API Error (#{e.message}). Retrying in #{sleep_time}s..."
        sleep(sleep_time)
        retry
      else
        log "API request failed after #{max_retries} retries: #{e.message}", :error
        nil
      end
    end
  end

  def fetch_new_comments(task_gid)
    # Get all comments & filter out already processed ones
    all_comments = fetch_task_comments(task_gid)
    all_comments.reject { |comment| @tracker.processed?(task_gid, comment[:gid]) }
  end

  def fetch_monitored_tasks
    # Get incomplete tasks from the project to monitor for comments
    # This is the same as fetch_incomplete_tasks for now
    # In future, could expand to include recently completed tasks or specific task lists
    fetch_incomplete_tasks
  end

  def process_task_comments(task)
    new_comments = fetch_new_comments(task.gid)
    return if new_comments.empty?

    log "Found #{new_comments.size} new comment(s) on task #{task.gid}: #{task.name}"

    new_comments.each do |comment|
      begin
        process_comment(task, comment)
      ensure
        # Always mark processed to avoid infinite loops on crashing/timeout comments
        @tracker.mark_processed(task.gid, comment[:gid])
      end
    end
  rescue => e
    log "ERROR processing comments for task #{task.gid}: #{e.message}", :error
    log e.backtrace.first(3).join("\n"), :error
  end

  def process_comment(task, comment)
    log "  Processing comment #{comment[:gid]}: #{comment[:text][0..50]}..."

    # Skip comments from the agent itself to prevent loops
    if comment[:created_by] == AgentConfig::AGENT_NAME
      log "    Skipping comment from agent (#{AgentConfig::AGENT_NAME})"
      return
    end

    # For now, only process comments from Tom
    unless comment[:created_by] == 'Tom Tunguz' || comment[:created_by] == 'Tomasz Tunguz'
      log "    Skipping comment from #{comment[:created_by]} (only processing comments from Tom/Tomasz Tunguz)"
      return
    end

    # Redundant check, but good for safety
    if agent_generated_comment?(comment[:text])
      log "    Skipping agent-generated comment text"
      return
    end

    # Check if task already has a successful AI response
    # Only reprocess if comment explicitly requests it or asks a follow-up question
    if task_already_has_successful_response?(task.gid)
      retry_keywords = ['retry', 'again', 'redo', 'rerun', 're-run', 'try again']
      followup_keywords = ['show', 'can you', 'could you', 'would you', 'please', 'what', 'where', 'how', 'why', 'explain', 'clarify', 'tell me', 'give me', 'provide', 'display']
      comment_lower = comment[:text].downcase

      # Check if user is asking to see email draft/email from previous execution
      if comment_lower.include?('show') && (comment_lower.include?('email') || comment_lower.include?('draft'))
        log "    User asking to see previous email draft - searching history"
        draft = extract_email_draft_from_history(task.gid)

        if draft
          log "    ✅ Found email draft in history"
          add_task_comment(task.gid, "📧 Email Draft from previous execution:\n\n#{draft}")
          return
        else
          log "    ⚠️ No email draft found in history - will re-execute"
          # Fall through to re-execute
        end
      end

      # Process if comment requests retry OR asks a follow-up question
      has_retry = retry_keywords.any? { |keyword| comment_lower.include?(keyword) }
      has_followup = followup_keywords.any? { |keyword| comment_lower.include?(keyword) } || comment[:text].include?('?')

      unless has_retry || has_followup
        log "    Skipping - task already has successful response & comment doesn't request retry or ask follow-up"
        return
      end

      if has_retry
        log "    Comment requests retry - will reprocess"
      else
        log "    Comment asks follow-up question - will reprocess"
      end
    end

    workflow = @router.route_from_comment(comment[:text], task)

    log "    Routing to #{workflow.class.name}"

    result = workflow.execute

    if result[:success]
      log "    ✅ Workflow succeeded"
      add_task_comment(task.gid, result[:comment])

      # Update task title to be more descriptive after successful processing
      update_task_title(task, result)

      # NOTE: Don't complete task when triggered by comment (keep open for more interaction)
    else
      log "    ❌ Workflow failed: #{result[:error]}", :error
      add_task_comment(task.gid, "❌ Workflow failed: #{result[:error]}")

      # ALWAYS update task title on failure to show what was attempted
      update_task_title(task, result)
    end
  rescue => e
    log "  ERROR processing comment #{comment[:gid]}: #{e.class}: #{e.message}", :error
    log e.backtrace.join("\n"), :error
    add_task_comment(task.gid, "❌ Agent error processing comment: #{e.message}")

    # Even on exception, try to update title with error context
    begin
      update_task_title(task, {success: false, error: e.message, comment: ''})
    rescue => title_error
      log "  ⚠️ Could not update title after exception: #{title_error.message}", :error
    end
  end

  def extract_email_draft_from_history(task_gid)
    # Search comment history for email drafts from GEPA or single-step executions
    comments = fetch_task_comments(task_gid)
    return nil if comments.empty?

    # Look through comments in reverse order (most recent first)
    comments.reverse_each do |comment|
      text = comment[:text] || ''

      # Skip non-agent comments
      next unless agent_generated_comment?(text)

      # Look for GEPA email draft sections
      if text.include?('━━━') && (text.include?('Email Draft') || text.include?('email') || text.include?('draft'))
        # Extract the email draft section
        if match = text.match(/━━━ Step \d+ : Email Draft ━━━\n(.*?)(?=\n━━━|$)/m)
          return match[1].strip
        end

        # Also try to extract from general step results that contain email content
        if match = text.match(/━━━ Step \d+ Result ━━━\n(.*?)(?=\n━━━|$)/m)
          content = match[1].strip
          # Check if this looks like an email (has Subject, To, etc.)
          if content.match?(/\b(Subject:|To:|From:|Dear |Hi |Hello )/i)
            return content
          end
        end
      end

      # Look for single-step email responses (Claude/Gemini Code Response)
      if text.include?('Code Response:') && text.match?(/\b(Subject:|To:|From:|Dear |Hi |Hello )/i)
        # Extract everything after "Code Response:"
        if match = text.match(/Code Response:\n\n(.*)/m)
          return match[1].strip
        end
      end
    end

    nil
  rescue => e
    log "Error extracting email draft from history: #{e.message}", :error
    nil
  end

  def agent_generated_comment?(text)
    # Skip comments that start with agent-generated prefixes
    return true if text.strip.start_with?('✅', '❌', '🤖', '⚠️', '🔄')

    # Also check for specific phrases just in case emojis are messed up
    return true if text.strip.start_with?("Gemini Code Response:")
    return true if text.strip.start_with?("Claude Code Response:")
    return true if text.include?("Workflow failed")
    return true if text.include?("Agent error")

    # GEPA progress comments & step results
    return true if text.include?("GEPA Multi-Step Execution")
    return true if text.match?(/━━━ Step \d+/)
    return true if text.match?(/Step \d+\/\d+ :/)

    false
  end

  def task_already_has_gemini_response?(task_gid)
    # Check if the LAST comment on this task is an AI response
    # This allows users to add new comments after an AI response to trigger re-processing
    comments = fetch_task_comments(task_gid)

    return false if comments.empty?

    last_comment = comments.last
    text = last_comment[:text] || ''

    agent_generated_comment?(text)
  rescue => e
    log "Error checking for existing Gemini response on task #{task_gid}: #{e.message}", :error
    # If we can't check, assume it doesn't have a response to avoid skipping tasks
    false
  end

  def task_already_has_successful_response?(task_gid)
    # Check if the LAST comment is a SUCCESSFUL AI response (not an error)
    comments = fetch_task_comments(task_gid)

    return false if comments.empty?

    last_comment = comments.last
    text = last_comment[:text] || ''

    # Must be an AI-generated comment AND not an error message
    return false unless agent_generated_comment?(text)

    # Check if it's an error/failure message
    is_error = text.include?('❌') ||
               text.include?('Workflow failed') ||
               text.include?('Agent error') ||
               text.include?('Error:')

    !is_error
  rescue => e
    log "Error checking for successful response on task #{task_gid}: #{e.message}", :error
    false
  end

  def fetch_incomplete_tasks
    # Use direct API call to get project tasks from all monitored projects
    all_tasks = []
    task_gids_seen = Set.new  # Track GIDs to avoid duplicates (tasks in multiple projects)

    @project_gids.each do |project_gid|
      url = "https://app.asana.com/api/1.0/projects/#{project_gid}/tasks?opt_fields=name,notes,gid,completed&completed_since=now&limit=100"
      response = execute_asana_request(url)

      next unless response && response.code == '200'

      begin
        body = response.body.force_encoding('UTF-8')
        data = JSON.parse(body, symbolize_names: true)
        
        data[:data].each do |task|
          # Skip if we've already seen this task (it's in multiple projects)
          next if task_gids_seen.include?(task[:gid])
          task_gids_seen.add(task[:gid])

          all_tasks << OpenStruct.new(
            gid: task[:gid],
            name: (task[:name] || '').force_encoding('UTF-8'),
            notes: (task[:notes] || '').force_encoding('UTF-8'),
            completed: task[:completed]
          )
        end
      rescue => e
        log "Error parsing tasks for project #{project_gid}: #{e.message}", :error
      end
    end

    all_tasks
  rescue => e
    log "Error fetching tasks: #{e.message}", :error
    log e.backtrace.first(3).join("\n"), :error
    []
  end

  def process_task(task)
    # Check skip condition first to avoid log noise
    # If task already has a successful response, we assume it's handled.
    # User interaction (comments) is handled separately by process_task_comments.
    if task_already_has_successful_response?(task.gid)
      return
    end

    log "Processing task #{task.gid}: #{task.name}"

    workflow = @router.route(task)

    log "  Routing to #{workflow.class.name}"

    result = workflow.execute

    if result[:success]
      log "  ✅ Workflow succeeded"
      add_task_comment(task.gid, result[:comment])

      # Update task title to be more descriptive after successful processing
      update_task_title(task, result)

      # NOTE: Don't auto-complete tasks - let user complete them manually
      # complete_task(task.gid)
    else
      log "  ❌ Workflow failed: #{result[:error]}", :error
      add_task_comment(task.gid, "❌ Workflow failed: #{result[:error]}")

      # ALWAYS update task title on failure to show what was attempted
      update_task_title(task, result)
    end
  rescue => e
    log "  ERROR processing task #{task.gid}: #{e.class}: #{e.message}", :error
    log e.backtrace.join("\n"), :error
    add_task_comment(task.gid, "❌ Agent error: #{e.message}")

    # Even on exception, try to update title with error context
    begin
      update_task_title(task, {success: false, error: e.message, comment: ''})
    rescue => title_error
      log "  ⚠️ Could not update title after exception: #{title_error.message}", :error
    end
  end

  def update_task_title(task, result)
    # Generate a descriptive title based on task content and workflow result
    new_title = generate_descriptive_title(task, result)

    # Only update if new title is different and meaningful
    if new_title && new_title != task.name && new_title.length > 5
      begin
        log "  Updating task title: '#{task.name}' → '#{new_title}'"
        update_task_title_direct(task.gid, new_title)
      rescue => e
        log "  ⚠️ Failed to update task title: #{e.message}", :error
      end
    else
      log "  Skipping title update: #{new_title ? "title unchanged" : "no new title generated"}"
    end
  end

  def update_task_title_direct(task_gid, new_title)
    # Direct Asana API call to update task title
    # Bypasses TaskAPI safety checks since agent monitor is designed to handle all team tasks
    require 'net/http'
    require 'json'
    require 'uri'

    url = URI("https://app.asana.com/api/1.0/tasks/#{task_gid}")

    request = Net::HTTP::Put.new(url)
    request["Authorization"] = "Bearer #{ENV['ASANA_API_KEY']}"
    request["Content-Type"] = "application/json"
    request.body = {
      data: {
        name: new_title
      }
    }.to_json

    response = Net::HTTP.start(url.hostname, url.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE, open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end

    if response.code != '200'
      raise "Asana API error: #{response.code} - #{response.body}"
    end

    log "  ✅ Task title updated successfully"
  rescue => e
    raise "Failed to update task title via Asana API: #{e.message}"
  end

  def generate_descriptive_title(task, result)
    # Extract key information from task notes and workflow result
    # to create a more descriptive title

    # Start with existing title as base
    current_title = task.name.to_s.strip

    # If title is already descriptive (>50 chars) and doesn't look generic, keep it
    # UNLESS it's an error/timeout case (we always want to update those)
    unless result[:success] == false || generic_title?(current_title) || current_title.length < 50
      return nil
    end

    # Extract information from different sources
    notes = task.notes.to_s.strip
    comment = result[:comment].to_s
    error = result[:error].to_s

    # ALWAYS try workflow-specific extraction first (works for both success & failure)
    new_title = extract_title_from_workflow(notes, comment, current_title)

    # If workflow extracted a title, use it
    if new_title && new_title.length >= 10
      # Clean up title (remove markdown, URLs, special chars)
      new_title = clean_title(new_title)
      # Add status indicator for failed workflows
      if !result[:success]
        new_title = "❌ #{new_title}" unless new_title.start_with?('❌', '⏱️')
      end
      return new_title[0..120]
    end

    # Handle error/timeout cases - extract what was being attempted
    if !result[:success]
      # Extract key context from error message & task notes
      context_from_notes = extract_context_from_notes(notes)

      # For timeouts, try to extract partial progress from comment
      if error.to_s.downcase.include?('timeout')
        # Check if there's partial progress in the comment (GEPA steps)
        partial_progress = extract_partial_progress(comment)

        if partial_progress && partial_progress.length >= 10
          new_title = "⏱️ Timeout (#{partial_progress})"
        elsif context_from_notes && context_from_notes.length >= 10
          new_title = "⏱️ Timeout : #{context_from_notes}"
        else
          # Use current title if it's descriptive, otherwise extract from notes
          if current_title.length > 15 && !generic_title?(current_title)
            new_title = "⏱️ Timeout : #{current_title}"
          else
            # Extract first meaningful phrase from notes
            phrase = extract_first_meaningful_phrase(notes)
            new_title = "⏱️ Workflow timeout : #{phrase}"
          end
        end
      else
        # For other errors, prefix with error indicator
        if context_from_notes && context_from_notes.length >= 10
          new_title = "❌ #{context_from_notes}"
        else
          # Extract from current title or notes
          if current_title.length > 15 && !generic_title?(current_title)
            new_title = "❌ Failed : #{current_title}"
          else
            phrase = extract_first_meaningful_phrase(notes)
            new_title = "❌ Failed : #{phrase}"
          end
        end
      end

      # Clean up title
      new_title = clean_title(new_title)
      return new_title[0..120]
    end

    # If no workflow-specific title, use general extraction
    # Extract first meaningful line from task notes
    first_line = notes.split("\n").reject { |l| l.strip.empty? }.first.to_s.strip

    # Extract from workflow result comment (first non-emoji, non-status line)
    result_lines = comment.split("\n").reject do |l|
      l.strip.empty? ||
      l.strip =~ /^[🤖✅❌⚠️🔄📧]/ ||
      l.include?('Code Response:') ||
      l.include?('━━━')
    end
    result_summary = result_lines.first.to_s.strip[0..100]

    # Try AI generation if other methods failed to produce a high-quality title
    ai_title = generate_ai_title(task, result)
    if ai_title && ai_title.length > 10
      return clean_title(ai_title)[0..120]
    end

    # Build descriptive title based on available information (Fallback)
    if first_line.length > 10
      # Use first line of notes if meaningful
      new_title = first_line[0..80]
    elsif result_summary.length > 10
      # Otherwise use result summary
      new_title = result_summary[0..80]
    else
      # Fallback: enhance current title with context
      phrase = extract_first_meaningful_phrase(notes)
      new_title = "#{phrase} - Processed"
    end

    # Clean up title (remove markdown, URLs, special chars)
    new_title = clean_title(new_title)

    # Ensure title is not too long (Asana limit is ~1024 chars, but keep reasonable)
    new_title[0..120]
  end

  def generate_ai_title(task, result)
    # Use LLM to generate a concise, descriptive title
    return nil unless @llm_client

    prompt = <<~PROMPT
      Generate a concise, descriptive title (max 10 words) for this Asana task based on its context and processing result.
      
      Task Name: #{task.name}
      Task Notes: #{task.notes.to_s[0..500]}...
      Processing Result: #{result[:success] ? 'Success' : 'Failure'}
      Result Summary: #{result[:comment].to_s[0..500]}...
      
      The title should:
      1. Start with a Category (e.g., "Research:", "Email:", "Summary:", "Analysis:")
      2. Be specific (include domain, company name, or subject)
      3. Be professional and clear
      4. NOT use markdown or emojis
      5. If failed, start with "Failed:"
      
      Output ONLY the title.
    PROMPT

    response = @llm_client.call(prompt, complexity: :simple)
    if response[:success]
      return response[:output].strip
    else
      log "  ⚠️ AI title generation failed: #{response[:error]}", :error
      return nil
    end
  rescue => e
    log "  ⚠️ Error in AI title generation: #{e.message}", :error
    nil
  end

  def extract_partial_progress(comment)
    # Extract what was completed before timeout (from GEPA step results)
    return nil if comment.nil? || comment.strip.empty?

    # Look for step completion indicators
    if comment =~ /Completed (\d+)\/(\d+) steps/
      completed = $1.to_i
      total = $2.to_i
      return "#{completed}/#{total} steps" if completed > 0
    end

    # Look for last successful step
    step_matches = comment.scan(/✅ Step (\d+)/)
    if step_matches.any?
      last_step = step_matches.last[0]
      return "through step #{last_step}"
    end

    nil
  end

  def extract_first_meaningful_phrase(text)
    # Extract first meaningful phrase from text (fallback for title generation)
    return "Task" if text.nil? || text.strip.empty?

    # Remove URLs first
    cleaned = text.gsub(/(https?:\/\/[^\s]+)/, '')

    # Get first non-empty line
    lines = cleaned.split("\n").reject { |l| l.strip.empty? }
    first_line = lines.first.to_s.strip

    return "Task" if first_line.empty?

    # Truncate to first sentence or 60 chars
    first_sentence = first_line.split(/[.!?]/).first.to_s.strip
    phrase = first_sentence.length > 0 ? first_sentence : first_line

    # Limit length
    phrase[0..60]
  end

  def extract_context_from_notes(notes)
    # Extract meaningful context from task notes for title generation
    # This helps identify what the task was about even if it failed
    return nil if notes.nil? || notes.strip.empty?

    # Try to find domain/company references
    # Match valid domain format: alphanumeric, hyphens, dots only
    if notes =~ /([a-z0-9.-]+\.(com|io|ai|co|net|org))/i
      domain = $1
      # Check for action verb before domain
      if notes =~ /(research|analyze|review|find|check|add|create|update)\s+.*?#{Regexp.escape(domain)}/i
        action = $1.capitalize
        return "#{action} #{domain}"
      end
      return domain
    end

    # Try to find email addresses
    if notes =~ /([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})/i
      email = $1
      # Extract name from email
      if email =~ /^([^@]+)@/
        name = $1.gsub(/[._]/, ' ').split.map(&:capitalize).join(' ')
        return "Email to #{name}"
      end
      return "Email to #{email}"
    end

    # Try to find URLs
    if notes =~ /(https?:\/\/[^\s]+)/
      url = $1
      # Extract domain for cleaner context
      if url =~ /https?:\/\/(?:www\.)?([^\/]+)/
        domain = $1
        return "Article from #{domain}"
      end
    end

    # Extract first meaningful line (not too short, not too long)
    lines = notes.split("\n").reject { |l| l.strip.empty? || l.strip.length < 10 }
    first_line = lines.first
    if first_line && first_line.length >= 10 && first_line.length <= 100
      return first_line.strip
    end

    # Extract action verbs with context
    action_patterns = [
      /^(research|analyze|review|summarize|create|draft|send|write|update|find|check|add)\s+(.{10,60})/i,
      /(research|analyze|review|summarize|create|draft|send|write|update|find|check|add)\s+(?:a|an|the)?\s*(.{10,60})/i
    ]

    action_patterns.each do |pattern|
      if notes =~ pattern
        action = $1.capitalize
        context = $2.strip
        # Clean up context (remove trailing punctuation, limit length)
        context = context.gsub(/[.,:;!?]+$/, '')[0..50]
        return "#{action} #{context}" if context.length >= 5
      end
    end

    nil
  end

  def generic_title?(title)
    # Check if title looks generic and should be replaced
    generic_patterns = [
      /^task$/i,
      /^todo$/i,
      /^new task$/i,
      /^untitled$/i,
      /^research$/i,
      /^draft$/i,
      /^email$/i,
      /^write$/i,
      /^create$/i,
      /^update$/i,
      /^rhonda task$/i,
      /^rhonda$/i
    ]

    generic_patterns.any? { |pattern| title.match?(pattern) }
  end

  def extract_title_from_workflow(notes, comment, current_title)
    # Extract domain/company from research workflows
    # Match valid domain format: alphanumeric, hyphens, dots (no quotes, parens, commas, etc.)
    if notes =~ /research\s+([a-z0-9.-]+\.[a-z]{2,})/i || comment =~ /research.*?([a-z0-9.-]+\.[a-z]{2,})/i
      domain = $1
      return "Research : #{domain}"
    end

    # Extract company/domain from Attio/CRM workflows
    # Match valid domain format: alphanumeric, hyphens, dots (no quotes, parens, commas, etc.)
    if notes =~ /attio.*?([a-z0-9.-]+\.[a-z]{2,})/i || comment =~ /company.*?([a-z0-9.-]+\.[a-z]{2,})/i
      domain = $1
      return "Company Review : #{domain}"
    end

    # Extract market map operations
    if notes =~ /market\s+map/i || comment =~ /market\s+map/i
      # Try to extract domain or market name
      if notes =~ /market\s+map.*?(?:for|about|on)?\s*["']?([^"'\n]{10,50})["']?/i
        context = $1.strip
        return "Market Map : #{context}"
      elsif notes =~ /([a-z0-9.-]+\.[a-z]{2,})/i
        domain = $1
        return "Market Map : #{domain}"
      end
      return "Market Map Generation"
    end

    # Extract email subject from email drafts
    if comment =~ /Subject:\s*(.+?)(?:\n|$)/
      subject = $1.strip
      return "Email : #{subject}" if subject.length > 5
    end

    # Extract recipient from email tasks
    if notes =~ /(?:email|write to|send to)\s+([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})/i
      email = $1
      # Extract name from email if possible
      if email =~ /^([^@]+)@/
        name = $1.gsub(/[._]/, ' ').split.map(&:capitalize).join(' ')
        return "Email to #{name}"
      end
    end

    # Extract URL from article summaries
    if notes =~ /(https?:\/\/[^\s]+)/
      url = $1
      # Extract domain for cleaner title
      if url =~ /https?:\/\/(?:www\.)?([^\/]+)/
        domain = $1
        return "Summary : #{domain}"
      end
    end

    # Extract query from search workflows
    if notes =~ /\bsearch\s+(?:for\s+)?["']?(.{10,50})["']?/i
      query = $1.strip
      return "Search : #{query}"
    end

    # Extract task/calendar events
    if notes =~ /(?:create task|add task|task for)\s+["']?(.{10,50})["']?/i
      task_desc = $1.strip
      return "Task : #{task_desc}"
    end

    if notes =~ /(?:schedule|calendar|meeting)\s+(?:with\s+)?["']?(.{10,50})["']?/i
      event_desc = $1.strip
      return "Calendar : #{event_desc}"
    end

    # Extract VCBench analysis tasks
    if notes =~ /vcbench/i || comment =~ /vcbench/i
      if notes =~ /([a-z0-9.-]+\.[a-z]{2,})/i
        domain = $1
        return "VCBench Analysis : #{domain}"
      end
      return "VCBench Company Analysis"
    end

    # Extract action verb + object patterns (more general)
    action_patterns = [
      [/^(analyze|review|summarize)\s+(?:a|an|the)?\s*(.{10,60})/i, "Analysis"],
      [/^(draft|write|compose)\s+(?:a|an|the)?\s*(.{10,60})/i, "Draft"],
      [/^(create|generate|build)\s+(?:a|an|the)?\s*(.{10,60})/i, "Create"],
      [/^(find|search|locate)\s+(?:a|an|the)?\s*(.{10,60})/i, "Search"],
      [/^(update|modify|change)\s+(?:a|an|the)?\s*(.{10,60})/i, "Update"]
    ]

    action_patterns.each do |pattern, prefix|
      if notes =~ pattern
        context = $2.strip.gsub(/[.,:;!?]+$/, '')[0..50]
        return "#{prefix} : #{context}" if context.length >= 5
      end
    end

    # Extract first sentence from notes if nothing else matches
    if notes.length > 20
      first_sentence = notes.split(/[.!?]/).first.to_s.strip
      if first_sentence.length > 15 && first_sentence.length < 100
        return first_sentence
      end
    end

    nil
  end

  def clean_title(title)
    # Remove markdown formatting
    result = title.dup

    # Remove URLs
    result.gsub!(/(https?:\/\/[^\s]+)/, '')

    # Remove markdown code blocks
    result.gsub!(/```[a-z]*\n(.*?)\n```/m, '\1')

    # Remove inline code
    result.gsub!(/`([^`]+)`/, '\1')

    # Remove bold/italic
    result.gsub!(/\*\*([^*]+)\*\*/, '\1')
    result.gsub!(/\*([^*]+)\*/, '\1')

    # Remove headers
    result.gsub!(/^[#]{1,6}\s+/, '')

    # Remove emoji
    result.gsub!(/[🤖✅❌⚠️🔄📧]/, '')

    # Collapse multiple spaces
    result.gsub!(/\s+/, ' ')

    result.strip
  end

  def add_task_comment(task_gid, text)
    # Use TaskAPI for adding comments
    result = TaskAPI.add_comment(task_id: task_gid, comment: text)
    if result.is_a?(Hash) && result[:success] == false
      log "Failed to add comment to task #{task_gid}: #{result[:error] || result[:message]}", :error
    end
  rescue => e
    log "Failed to add comment to task #{task_gid}: #{e.message}", :error
  end

  def complete_task(task_gid)
    # Use TaskAPI for completing tasks
    TaskAPI.complete(task_id: task_gid, format: :concise)
  rescue => e
    log "Failed to complete task #{task_gid}: #{e.message}", :error
  end

  def log(message, level = :info)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    formatted = "[#{timestamp}] [#{level.upcase}] #{message}"

    @log_mutex.synchronize do
      # Write to log file
      File.open(AgentConfig::LOG_FILE, 'a') do |f|
        f.puts formatted
      end

      # Also print to stdout
      puts formatted
    end
  end

  def load_env_secrets
    env_file = File.expand_path('~/.asana-monitor-env')
    return unless File.exist?(env_file)

    File.readlines(env_file).each do |line|
      next if line.strip.start_with?('#')
      # Match export KEY="VALUE" or export KEY=VALUE
      if line =~ /export\s+([A-Z_]+)=["']?([^"'\n]+)["']?/
        key, value = $1, $2
        # Only set if not already set (preserve process ENV if passed explicitly)
        ENV[key] ||= value
      end
    end
  rescue => e
    # Don't crash on env loading, just log to stderr (logger might not be ready)
    warn "[AgentMonitor] Failed to load .asana-monitor-env: #{e.message}"
  end
end
