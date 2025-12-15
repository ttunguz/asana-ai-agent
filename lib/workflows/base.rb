# lib/workflows/base.rb

require 'uri'
require_relative '../../config/agent_config'

module Workflows
  class Base
    attr_reader :task, :triggered_by, :comment_text, :all_comments

    def initialize(task, triggered_by: :task, comment_text: nil, all_comments: [])
      @task = task
      @triggered_by = triggered_by  # :task or :comment
      @comment_text = comment_text  # Comment text when triggered_by == :comment
      @all_comments = all_comments || []  # Full comment history for context
    end

    # Each workflow must implement execute method
    # Returns: { success: true/false, comment: "...", error: "..." }
    def execute
      raise NotImplementedError, "Subclass must implement execute method"
    end

    # Check if workflow was triggered by a comment
    def from_comment?
      @triggered_by == :comment
    end

    protected

    # Helper: Extract domain from text
    def extract_domain(text)
      # Match domain patterns
      if text.match?(/^https?:\/\//)
        uri = URI.parse(text)
        uri.host.sub(/^www\./, '')
      elsif text.match?(/([a-z0-9.-]+\.(com|ai|io|co|net|org))/i)
        text.match(/([a-z0-9.-]+\.(com|ai|io|co|net|org))/i)[1]
      else
        nil
      end
    rescue => e
      log_error("Failed to extract domain from '#{text}': #{e.message}")
      nil
    end

    # Helper: Create follow-up task for Tom
    def create_tom_task(title:, notes:)
      require '/Users/tomasztunguz/.gemini/code_mode/task_api'

      TaskAPI.create(
        title: title,
        assignee: 'tom',
        due_date: Date.today.to_s,
        notes: notes,
        project: 'agent_tasks',
        format: :concise
      )
    rescue => e
      log_error("Failed to create task for Tom: #{e.message}")
      nil
    end

    # Helper: Log errors
    def log_error(message)
      File.open(AgentConfig::LOG_FILE, 'a') do |f|
        f.puts "[#{Time.now}] [ERROR] [#{self.class.name}] #{message}"
      end
    end

    # Helper: Log info
    def log_info(message)
      File.open(AgentConfig::LOG_FILE, 'a') do |f|
        f.puts "[#{Time.now}] [INFO] [#{self.class.name}] #{message}"
      end
    end
  end
end
