# lib/workflow_router.rb
# Router with robust AI workflow as optional enhancement

require_relative 'workflows/gemini_code'

class WorkflowRouter
  def initialize(agent_monitor)
    @agent_monitor = agent_monitor
    @use_robust = ENV['USE_ROBUST_AI'] == 'true'  # Opt-in to robust workflow

    # Try to load robust workflow if enabled
    if @use_robust
      begin
        require_relative 'workflows/robust_ai_workflow'
        @robust_available = true
      rescue LoadError => e
        puts "[INFO] Robust AI workflow not available: #{e.message}"
        @robust_available = false
      end
    end
  end

  def route(task)
    # Fetch all comments for context
    all_comments = @agent_monitor.fetch_task_comments(task.gid)

    # Use robust workflow if enabled and available
    if @use_robust && @robust_available
      Workflows::RobustAIWorkflow.new(task, all_comments: all_comments)
    else
      # Default to GeminiCode workflow (now includes DPSY & GEPA)
      Workflows::GeminiCode.new(task, all_comments: all_comments)
    end
  end

  def route_from_comment(comment_text, task)
    # Fetch all comments for full conversation context
    all_comments = @agent_monitor.fetch_task_comments(task.gid)

    # Use robust workflow if enabled and available
    if @use_robust && @robust_available
      Workflows::RobustAIWorkflow.new(
        task,
        triggered_by: :comment,
        comment_text: comment_text,
        all_comments: all_comments
      )
    else
      # Default to GeminiCode workflow with comment text & full history
      Workflows::GeminiCode.new(task, triggered_by: :comment, comment_text: comment_text, all_comments: all_comments)
    end
  end
end
