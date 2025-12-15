# lib/workflows/robust_ai_workflow.rb
# Improved AI workflow using robust LLM client, prompt engineering, and response validation
# encoding: utf-8

require_relative 'base'
require_relative '../llm/robust_client'
require_relative '../llm/prompt_engineer'
require_relative '../llm/response_validator'
require 'json'

module Workflows
  class RobustAIWorkflow < Base
    def initialize(task, triggered_by: :task, comment_text: nil, all_comments: nil)
      super
      @llm_client = LLM::RobustClient.new(logger: logger)
      @prompt_engineer = LLM::PromptEngineer.new(logger: logger)
      @response_validator = LLM::ResponseValidator.new(logger: logger)
    end

    def execute
      @start_time = Time.now
      log_info("Executing Robust AI workflow for task: #{task.name}")
      
      @execution_history = []
      max_steps = 5
      
      (1..max_steps).each do |step|
        log_info("Step #{step}/#{max_steps}")
        
        # 1. Build engineered prompt with history
        prompt = build_step_prompt(step, max_steps)
        
        # 2. Call LLM
        complexity = determine_task_complexity
        llm_response = @llm_client.call(prompt, complexity: complexity, context: build_context)
        
        # 3. Validate response
        validation = @response_validator.validate(
          llm_response[:output], 
          format: :structured,
          require_safety_features: true
        )
        
        unless validation[:success]
          handle_validation_failure(validation)
          # Add failure to history and retry in next step (LLM will see the error)
          @execution_history << { step: step, action: 'validation_error', error: validation[:error] }
          next
        end
        
        # 4. Check if LLM wants to finish
        if llm_response[:output].include?('FINAL_ANSWER') || llm_response[:output].include?('NO_MORE_STEPS')
           return {
             success: true,
             comment: format_success_response(llm_response, validation, @execution_history),
             metrics: gather_metrics
           }
        end

        # 5. Execute validated code
        if validation[:code_blocks].any?
          execution_results = execute_validated_code(validation)
          
          # Record results
          @execution_history << {
            step: step,
            action: 'code_execution',
            results: execution_results,
            llm_output: llm_response[:output]
          }
          
          # If all code executed successfully and it looks like a final step, we might be done
          # But we generally let the LLM decide in the next turn or if it explicitly said FINAL_ANSWER
        else
          # No code, just text response. Treat as intermediate thought or final answer if it looks like one.
          @execution_history << {
            step: step,
            action: 'thought',
            llm_output: llm_response[:output]
          }
        end
      end
      
      # If we run out of steps
      {
        success: false,
        error: "Exceeded maximum steps (#{max_steps})",
        comment: "❌ Workflow timed out after #{max_steps} steps. Partial progress:\n#{format_history_summary}"
      }
    rescue => e
      log_error("Unexpected error in robust AI workflow: #{e.class}: #{e.message}")
      log_error(e.backtrace.first(5).join("\n"))
      {
        success: false, 
        error: e.message,
        comment: "❌ Unexpected error: #{e.message}"
      }
    end

    private

    def build_step_prompt(step, max_steps)
      base_prompt = build_engineered_prompt
      
      history_text = @execution_history.map do |h|
        "Step #{h[:step]} (#{h[:action]}):\n#{format_step_result(h)}"
      end.join("\n---\n")
      
      <<~PROMPT
        #{base_prompt}
        
        CURRENT STATUS: Step #{step} of #{max_steps}
        
        PREVIOUS EXECUTION HISTORY:
        #{history_text.empty? ? "(None - Start of workflow)" : history_text}
        
        INSTRUCTIONS FOR THIS STEP:
        1. Review the history. If previous steps failed, analyze why and propose a fix.
        2. If you need to run code, provide the Ruby code block.
        3. If you are done, include "FINAL_ANSWER" in your response along with the final summary.
        4. If you need more steps, explain what you are doing next.
      PROMPT
    end

    def format_step_result(history_item)
      if history_item[:results]
        history_item[:results].map { |r| r[:success] ? "✅ Success: #{r[:output]}" : "❌ Error: #{r[:error]}" }.join("\n")
      elsif history_item[:error]
        "❌ Validation Error: #{history_item[:error]}"
      else
        "Thought: #{history_item[:llm_output][0..100]}..."
      end
    end

    def format_history_summary
      @execution_history.map do |h|
        if h[:results]
           h[:results].map { |r| r[:success] ? "Step #{h[:step]}: ✅ Code executed" : "Step #{h[:step]}: ❌ #{r[:error]}" }.join("\n")
        else
           "Step #{h[:step]}: #{h[:action]}"
        end
      end.join("\n")
    end

    def format_success_response(llm_response, validation, execution_history)
      # Enhanced success response with history
      summary = ""
      
      # Header with model info
      model = llm_response[:model] || "AI"
      confidence = (validation[:confidence] * 100).round
      summary << "🤖 #{model} Response (#{confidence}% confidence):\n"

      # Add response output
      summary << llm_response[:output]
      
      # Add execution results if code was run
      last_result = execution_history.last ? execution_history.last[:results] : []
      if last_result && last_result.any? { |r| r[:success] }
        summary << "\n\n📊 Execution Results:"
        last_result.each do |result|
          if result[:success]
            summary << "\n✅ Code executed successfully"
            summary << "\nOutput: #{result[:output]}" if result[:output] && !result[:output].empty?
          else
            summary << "\n❌ Execution failed: #{result[:error]}"
          end
        end
      end
      
      # Add history summary if multiple steps
      if execution_history.size > 1
        history_summary = format_history_summary
        summary << "\n\n🔄 Execution Steps:\n#{history_summary}"
      end
      
      summary
    end

    def build_engineered_prompt
      task_data = {
        type: detect_task_type,
        name: task.name,
        description: task.notes,
        comments: format_comments_for_prompt
      }

      # Add latest request if from comment
      if from_comment? && @comment_text
        task_data[:latest_request] = @comment_text
      end

      # Use prompt engineer to build optimized prompt
      @prompt_engineer.build_prompt(
        task: task_data,
        context: build_context,
        model: preferred_model,
        options: { structured: true }
      )
    end

    def detect_task_type
      name_lower = task.name.downcase
      notes_lower = (task.notes || "").downcase

      if name_lower.match?(/email|inbox|newsletter/)
        :email
      elsif name_lower.match?(/company|research|crm|attio/)
        :company_research
      elsif name_lower.match?(/task|todo|asana/)
        :task_management
      elsif name_lower.match?(/calendar|meeting|schedule/)
        :calendar
      else
        :general
      end
    end

    def format_comments_for_prompt
      return [] unless all_comments && all_comments.any?

      all_comments.map do |comment|
        {
          created_by: comment[:created_by] || "Unknown",
          created_at: comment[:created_at],
          text: (comment[:text] || "").force_encoding('UTF-8').scrub
        }
      end
    end

    def build_context
      context = {}

      # Add recent task history if available
      if defined?(@task_history) && @task_history
        context[:recent_activity] = @task_history.last(5).map(&:name).join(", ")
      end

      # Add user preferences
      context[:user_preferences] = {
        email_format: "concise",
        auto_execute: true,
        preferred_apis: "Code Mode APIs in ~/.gemini/code_mode/"
      }

      context
    end

    def determine_task_complexity
      # Analyze task to determine complexity
      total_length = task.name.length + (task.notes || "").length
      comment_count = all_comments ? all_comments.size : 0

      # Check for complex indicators
      has_multiple_steps = task.notes && task.notes.match?(/\d+\.|step|first.*then/i)
      has_code_request = @comment_text && @comment_text.match?(/code|script|automate/i)
      has_research = task.name.match?(/research|analyze|evaluate/i)

      if total_length > 5000 || comment_count > 10 || has_research
        :complex
      elsif total_length > 1000 || has_multiple_steps || has_code_request
        :moderate
      else
        :simple
      end
    end

    def preferred_model
      # Could be configured per environment
      ENV['PREFERRED_LLM_MODEL'] || 'claude-3-sonnet'
    end

    def execute_validated_code(validation)
      return nil unless validation[:code_blocks].any?

      # Only execute Ruby code blocks that passed validation
      executable_blocks = validation[:code_blocks].select do |block|
        block[:language] == 'ruby' && validation[:validation].find { |v| v[:risk_level] != :critical }
      end

      return nil if executable_blocks.empty?

      results = []
      executable_blocks.each do |block|
        begin
          log_info("Executing validated Ruby code (#{block[:line_count]} lines)")

          # Use sanitized version if available
          code_to_execute = validation[:sanitized] || block[:code]

          # Execute in a somewhat sandboxed way
          result = execute_ruby_safely(code_to_execute)
          results << {
            success: true,
            output: result
          }

        rescue => e
          log_error("Code execution failed: #{e.message}")
          results << {
            success: false,
            error: e.message
          }
        end
      end

      results
    end

    def execute_ruby_safely(code)
      # Write to temp file and execute with timeout
      temp_file = "/tmp/ai_task_#{Time.now.to_i}.rb"

      begin
        # Add safety wrapper
        wrapped_code = <<~RUBY
          #!/usr/bin/env ruby
          # encoding: utf-8

          require 'timeout'

          begin
            Timeout.timeout(30) do
              #{code}
            end
          rescue Timeout::Error
            puts "Execution timed out after 30 seconds"
            exit 1
          rescue => e
            puts "Error: \#{e.message}"
            puts e.backtrace.first(3).join("\\n")
            exit 1
          end
        RUBY

        File.write(temp_file, wrapped_code)
        File.chmod(0755, temp_file)

        # Execute with timeout
        output = `timeout 35 ruby #{temp_file} 2>&1`
        exit_status = $?.exitstatus

        if exit_status == 0
          output
        else
          raise "Execution failed with exit code #{exit_status}: #{output}"
        end

      ensure
        File.delete(temp_file) if File.exist?(temp_file)
      end
    end


    def handle_validation_failure(validation)
      log_error("Response validation failed: #{validation[:error]}")

      issues_summary = if validation[:issues]
                         validation[:issues].map { |i| "- #{i[:message]}" }.join("\n")
                       else
                         validation[:error]
                       end

      {
        success: false,
        error: "Response validation failed",
        comment: "❌ AI response failed safety validation:\n#{issues_summary}"
      }
    end

    def gather_metrics
      # Collect metrics for monitoring
      {
        llm_metrics: @llm_client.report_metrics,
        validation_stats: @response_validator.report_stats,
        prompt_size: @last_prompt_size,
        execution_time: Time.now - @start_time
      }
    end

    def logger
      @logger ||= Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'logs', 'robust_ai.log'))
    end

    def log_info(message)
      logger.info("[RobustAI] #{message}")
      puts "[#{Time.now}] #{message}" if ENV['DEBUG']
    end

    def log_error(message)
      logger.error("[RobustAI] #{message}")
      puts "[#{Time.now}] ERROR: #{message}"
    end
  end
end