# lib/llm/base_client.rb
# Factory for creating LLM clients based on configuration

require 'json'
require 'net/http'
require 'uri'

module LLM
  class BaseClient
    class << self
      def create(provider: nil, api_key: nil, model: nil)
        provider ||= AgentConfig.ai_provider
        api_key ||= AgentConfig.ai_api_key(provider)
        model ||= AgentConfig.ai_model(provider)

        unless api_key
          raise ArgumentError, "API key required for #{provider}. Set it in config.yml or environment."
        end

        case provider.to_sym
        when :gemini
          require_relative 'gemini_client'
          GeminiClient.new(api_key: api_key, model: model)
        when :claude, :anthropic
          require_relative 'claude_client'
          ClaudeClient.new(api_key: api_key, model: model)
        when :openai, :gpt
          require_relative 'openai_client'
          OpenAIClient.new(api_key: api_key, model: model)
        when :perplexity
          require_relative 'perplexity_client'
          PerplexityClient.new(api_key: api_key, model: model)
        else
          raise ArgumentError, "Unknown provider: #{provider}. Supported: gemini, claude, openai, perplexity"
        end
      end

      # Get all enabled providers from config
      def enabled_providers
        providers = []
        ai_config = AgentConfig.config.dig('ai') || {}

        ai_config.each do |provider_name, settings|
          next unless settings.is_a?(Hash)
          if settings['enabled'] && settings['api_key']
            providers << {
              name: provider_name.to_sym,
              model: settings['model'],
              api_key: settings['api_key']
            }
          end
        end

        providers
      end

      # Create client for first enabled provider
      def default
        provider = enabled_providers.first
        raise "No AI providers enabled in config.yml" unless provider

        create(
          provider: provider[:name],
          api_key: provider[:api_key],
          model: provider[:model]
        )
      end
    end
  end

  # Base class for all LLM clients
  class ClientBase
    attr_reader :api_key, :model

    def initialize(api_key:, model:)
      @api_key = api_key
      @model = model
    end

    # Must be implemented by subclasses
    def call(prompt, max_tokens: 4096, temperature: 0.7)
      raise NotImplementedError, "Subclass must implement #call"
    end

    protected

    def make_request(url, headers, body, max_retries: 3)
      retries = 0

      begin
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)

        headers.each { |k, v| request[k] = v }
        request.body = body.to_json if body.is_a?(Hash)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) do |http|
          http.request(request)
        end

        # Handle rate limiting
        if response.code == '429'
          retry_after = response['Retry-After']&.to_i || 60
          raise RateLimitError, "Rate limit exceeded. Retry after #{retry_after}s"
        end

        # Handle server errors
        if response.code.to_i >= 500
          raise "Server error: #{response.code}"
        end

        response

      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
        retries += 1
        if retries <= max_retries
          sleep_time = 2 ** retries
          sleep(sleep_time)
          retry
        else
          raise "Network error after #{max_retries} retries: #{e.message}"
        end
      rescue RateLimitError, RuntimeError => e
        retries += 1
        if retries <= max_retries && e.message.include?('Rate limit')
          sleep(60)
          retry
        else
          raise
        end
      end
    end

    def estimate_tokens(text)
      # Rough estimate: ~4 characters per token
      (text.length / 4.0).ceil
    end
  end

  class RateLimitError < StandardError; end
  class TimeoutError < StandardError; end
end
