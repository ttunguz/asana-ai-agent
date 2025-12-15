# config/agent_config.rb
require 'yaml'
require 'erb'

module AgentConfig
  class ConfigurationError < StandardError; end

  class << self
    attr_reader :config

    def load_config(path = nil)
      path ||= File.expand_path('../../config/config.yml', __FILE__)

      unless File.exist?(path)
        raise ConfigurationError, <<~ERROR
          Configuration file not found: #{path}

          Please copy config/config.example.yml to config/config.yml and fill in your values:
            cp config/config.example.yml config/config.yml
        ERROR
      end

      # Parse YAML with ERB for environment variable substitution
      yaml_content = File.read(path)
      processed_content = ERB.new(yaml_content).result
      @config = YAML.safe_load(processed_content, permitted_classes: [Symbol], aliases: true)

      validate_config!
      @config
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "Invalid YAML syntax in config file: #{e.message}"
    end

    def validate_config!
      errors = []

      # Validate Asana configuration
      errors << "asana.api_key is required" unless config.dig('asana', 'api_key')
      errors << "asana.workspace_gid is required" unless config.dig('asana', 'workspace_gid')
      errors << "asana.project_gid is required" unless config.dig('asana', 'project_gid')

      # Validate at least one AI provider is enabled
      ai_providers = config.dig('ai') || {}
      enabled_providers = ai_providers.select { |_, v| v.is_a?(Hash) && v['enabled'] }

      if enabled_providers.empty?
        errors << "At least one AI provider must be enabled (gemini, claude, openai, or perplexity)"
      end

      # Validate enabled AI providers have API keys
      enabled_providers.each do |provider, settings|
        unless settings['api_key'] && !settings['api_key'].empty?
          errors << "ai.#{provider}.api_key is required when #{provider} is enabled"
        end
      end

      unless errors.empty?
        raise ConfigurationError, "Configuration errors:\n  - #{errors.join("\n  - ")}"
      end
    end

    # Helper methods for accessing config values
    def asana_api_key
      config.dig('asana', 'api_key')
    end

    def asana_workspace_gid
      config.dig('asana', 'workspace_gid')
    end

    def asana_project_gid
      config.dig('asana', 'project_gid')
    end

    def asana_project_gids
      # Support multiple projects if configured
      gids = config.dig('asana', 'project_gids') || [asana_project_gid]
      gids.compact
    end

    def assignees
      config.dig('asana', 'users') || {}
    end

    def assignee_gid(name)
      assignees[name.to_s.downcase]
    end

    def poll_interval
      config.dig('agent', 'poll_interval') || 60
    end

    def comment_monitoring_enabled?
      config.dig('agent', 'comment_monitoring') != false
    end

    def max_tasks_per_cycle
      config.dig('agent', 'max_tasks_per_cycle') || 10
    end

    def parallel_processing_enabled?
      config.dig('agent', 'parallel_processing') != false
    end

    def title_update_mode
      config.dig('agent', 'title_update_mode') || 'prefix'
    end

    def workflow_enabled?(workflow_name)
      config.dig('workflows', workflow_name, 'enabled') != false
    end

    def workflow_keywords(workflow_name)
      config.dig('workflows', workflow_name, 'keywords') || []
    end

    def ai_provider
      # Return first enabled AI provider
      ai_providers = config.dig('ai') || {}
      enabled = ai_providers.find { |_, v| v.is_a?(Hash) && v['enabled'] }
      enabled&.first&.to_sym
    end

    def ai_provider_config(provider)
      config.dig('ai', provider.to_s)
    end

    def ai_api_key(provider = nil)
      provider ||= ai_provider
      config.dig('ai', provider.to_s, 'api_key')
    end

    def ai_model(provider = nil)
      provider ||= ai_provider
      config.dig('ai', provider.to_s, 'model')
    end

    def log_level
      level = config.dig('logging', 'level') || 'INFO'
      level.downcase.to_sym
    end

    def log_file
      config.dig('logging', 'file') || 'logs/agent.log'
    end

    def error_log_file
      config.dig('logging', 'error_file') || 'logs/agent-error.log'
    end

    # Code Mode APIs (optional)
    def task_api_path
      config.dig('code_mode', 'task_api_path')
    end

    def email_api_path
      config.dig('code_mode', 'email_api_path')
    end

    def attio_api_path
      config.dig('code_mode', 'attio_api_path')
    end

    def code_mode_enabled?
      task_api_path || email_api_path || attio_api_path
    end
  end

  # Legacy constants for backward compatibility
  # These will be removed in a future version
  def self.define_legacy_constants
    load_config unless @config

    const_set(:ASANA_PROJECT_GID, asana_project_gid) unless const_defined?(:ASANA_PROJECT_GID)
    const_set(:ASANA_PROJECT_GIDS, asana_project_gids) unless const_defined?(:ASANA_PROJECT_GIDS)
    const_set(:ASANA_WORKSPACE_GID, asana_workspace_gid) unless const_defined?(:ASANA_WORKSPACE_GID)
    const_set(:ASSIGNEES, assignees.freeze) unless const_defined?(:ASSIGNEES)
    const_set(:ENABLE_COMMENT_MONITORING, comment_monitoring_enabled?) unless const_defined?(:ENABLE_COMMENT_MONITORING)
    const_set(:LOG_DIR, File.dirname(log_file)) unless const_defined?(:LOG_DIR)
    const_set(:LOG_FILE, log_file) unless const_defined?(:LOG_FILE)
    const_set(:LOG_LEVEL, log_level) unless const_defined?(:LOG_LEVEL)
  end
end

# Load configuration when module is required
AgentConfig.load_config
AgentConfig.define_legacy_constants
