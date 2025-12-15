# lib/llm/robust_client.rb
# Robust LLM client with retry logic, fallback strategies, and monitoring
# encoding: utf-8

require 'json'
require 'open3'
require 'timeout'
require 'logger'

module LLM
  class RobustClient
    # Model configurations with cost and capability info
    MODELS = {
      simple: {
        models: ['gemini-flash', 'claude-3-haiku'],
        max_retries: 2,
        timeout: 60,
        cost_per_1k: { input: 0.00025, output: 0.00125 }
      },
      moderate: {
        models: ['gemini-3-pro-preview', 'claude-4.5-sonnet'],
        max_retries: 3,
        timeout: 180,
        cost_per_1k: { input: 0.003, output: 0.015 }
      },
      complex: {
        models: ['gemini-3-pro-preview', 'claude-4.5-sonnet'],
        max_retries: 3,
        timeout: 300,
        cost_per_1k: { input: 0.015, output: 0.075 }
      }
    }

    # Rate limit tracking
    class RateLimiter
      def initialize
        @windows = {}
      end

      def can_call?(model)
        window = @windows[model] ||= []
        now = Time.now

        # Clean old entries (older than 1 minute)
        window.reject! { |t| now - t > 60 }

        # Check rate limit (max 10 per minute for safety)
        if window.size >= 10
          false
        else
          window << now
          true
        end
      end

      def wait_time(model)
        window = @windows[model] || []
        return 0 if window.empty?

        oldest = window.min
        wait = 61 - (Time.now - oldest)
        wait > 0 ? wait : 0
      end
    end

    def initialize(logger: nil)
      @logger = logger || Logger.new(STDOUT)
      @rate_limiter = RateLimiter.new
      @metrics = {
        calls: Hash.new(0),
        successes: Hash.new(0),
        failures: Hash.new(0),
        total_cost: 0.0,
        total_tokens: { input: 0, output: 0 }
      }
    end

    # Main entry point with automatic complexity detection
    def call(prompt, complexity: :auto, context: {})
      complexity = detect_complexity(prompt) if complexity == :auto
      config = MODELS[complexity]

      @logger.info("LLM call with complexity: #{complexity}")

      last_error = nil
      responses = []

      config[:models].each_with_index do |model, attempt|
        begin
          # Check rate limit
          unless @rate_limiter.can_call?(model)
            wait_time = @rate_limiter.wait_time(model)
            @logger.warn("Rate limit reached for #{model}, waiting #{wait_time}s")
            sleep(wait_time)
          end

          # Exponential backoff for retries
          if attempt > 0
            backoff = 2 ** attempt + rand(0..1.0)
            @logger.info("Retry #{attempt} after #{backoff.round(1)}s")
            sleep(backoff)
          end

          # Make the call with timeout
          response = call_model_with_timeout(
            model: model,
            prompt: prompt,
            timeout: config[:timeout],
            context: context
          )

          # Validate response
          if valid_response?(response)
            track_success(model, response, complexity)
            return enhance_response(response, model, attempt)
          else
            @logger.warn("Invalid response from #{model}: #{response[:error]}")
            responses << response
            last_error = "Invalid response format"
          end

        rescue RateLimitError => e
          @logger.warn("Rate limit hit for #{model}: #{e.message}")
          last_error = e.message
          # Try next model immediately

        rescue TimeoutError => e
          @logger.error("Timeout for #{model} after #{config[:timeout]}s")
          last_error = "Timeout after #{config[:timeout]}s"
          # Try next model

        rescue => e
          @logger.error("Error with #{model}: #{e.class} - #{e.message}")
          last_error = e.message
          track_failure(model, e)
        end
      end

      # All models failed - return safe fallback
      fallback_response(prompt, last_error, responses)
    end

    def report_metrics
      @metrics
    end

    private

    def detect_complexity(prompt)
      # Simple heuristic based on prompt length and content
      length = prompt.length

      # Check for complex indicators
      has_code = prompt.include?('```') || prompt.include?('def ') || prompt.include?('class ')
      has_analysis = prompt.match?(/analyze|evaluate|compare|assess/i)
      has_multiple_steps = prompt.match?(/first.*then|step \d+|multiple/i)

      if length > 10000 || has_analysis || has_multiple_steps
        :complex
      elsif length > 2000 || has_code
        :moderate
      else
        :simple
      end
    end

    def call_model_with_timeout(model:, prompt:, timeout:, context:)
      response = nil

      Timeout.timeout(timeout) do
        case model
        when /claude/
          response = call_claude(model, prompt, context)
        when /gemini/
          response = call_gemini(model, prompt, context)
        when /gpt/
          response = call_openai(model, prompt, context)
        else
          raise "Unknown model: #{model}"
        end
      end

      response
    rescue Timeout::Error
      raise TimeoutError, "Model call timed out after #{timeout}s"
    end

    def call_claude(model, prompt, context)
      # Map model names to Claude CLI parameters
      model_param = case model
                    when 'claude-3-opus' then 'opus'
                    when 'claude-3-sonnet' then 'sonnet'
                    when 'claude-3-haiku' then 'haiku'
                    when 'claude-4.5-sonnet' then 'sonnet'
                    else 'sonnet'
                    end

      cmd = "/Users/tomasztunguz/Library/pnpm/claude -p --model #{model_param} --dangerously-skip-permissions"

      stdout, stderr, status = Open3.capture3(cmd, stdin_data: prompt)

      if status.success?
        output = stdout.force_encoding('UTF-8').scrub('')

        {
          success: true,
          output: output,
          model: model,
          tokens: estimate_tokens(prompt, output)
        }
      else
        error_msg = stderr.force_encoding('UTF-8').scrub('')

        # Check for specific error types
        if error_msg.include?("rate_limit") || error_msg.include?("quota")
          raise RateLimitError, error_msg
        else
          {
            success: false,
            error: error_msg,
            model: model
          }
        end
      end
    end

    def call_gemini(model, prompt, context)
      # Map to Gemini executable
      model_param = model.include?('flash') ? '--fast' : ''

      # Use the custom Gemini wrapper if available
      gemini_path = if File.exist?('/Users/tomasztunguz/Documents/coding/gemini-local/bundle/gemini.js')
                      "node /Users/tomasztunguz/Documents/coding/gemini-local/bundle/gemini.js"
                    else
                      "gemini"
                    end

      cmd = "#{gemini_path} --approval-mode yolo #{model_param}"

      stdout, stderr, status = Open3.capture3(cmd, stdin_data: prompt)

      if status.success?
        output = stdout.force_encoding('UTF-8').scrub('')

        {
          success: true,
          output: output,
          model: model,
          tokens: estimate_tokens(prompt, output)
        }
      else
        error_msg = stderr.force_encoding('UTF-8').scrub('')

        # Clean up Gemini-specific warnings
        clean_error = error_msg.lines.reject { |l|
          l.include?("[WARN]") || l.include?("YOLO mode")
        }.join.strip

        {
          success: false,
          error: clean_error.empty? ? "Gemini execution failed" : clean_error,
          model: model
        }
      end
    end

    def call_openai(model, prompt, context)
      # Placeholder for OpenAI integration
      # Would need API key configuration
      {
        success: false,
        error: "OpenAI integration not configured",
        model: model
      }
    end

    def valid_response?(response)
      return false unless response.is_a?(Hash)
      return false unless response[:success]
      return false if response[:output].nil? || response[:output].empty?

      # Additional validation for code responses
      if response[:output].include?('```')
        # Check if code blocks are properly closed
        code_blocks = response[:output].scan(/```[\w]*\n(.*?)```/m)
        return false if code_blocks.empty?

        # Try to validate Ruby syntax if it's Ruby code
        code_blocks.each do |block|
          if response[:output].include?('```ruby')
            begin
              # Basic syntax check
              RubyVM::InstructionSequence.compile(block[0])
            rescue SyntaxError => e
              @logger.warn("Invalid Ruby syntax in response: #{e.message}")
              return false
            end
          end
        end
      end

      true
    end

    def enhance_response(response, model, attempt)
      response.merge(
        retries: attempt,
        timestamp: Time.now.iso8601,
        complexity: detect_complexity_from_response(response[:output]),
        confidence: calculate_confidence(response, attempt)
      )
    end

    def detect_complexity_from_response(output)
      # Analyze response to categorize complexity
      lines = output.lines.size
      code_blocks = output.scan(/```/).size / 2

      if lines > 100 || code_blocks > 3
        :complex
      elsif lines > 30 || code_blocks > 1
        :moderate
      else
        :simple
      end
    end

    def calculate_confidence(response, attempt)
      # Lower confidence with more retries
      base_confidence = 0.95
      retry_penalty = attempt * 0.1

      confidence = base_confidence - retry_penalty

      # Adjust based on response quality indicators
      if response[:output].include?("error") || response[:output].include?("failed")
        confidence -= 0.2
      end

      if response[:output].include?("```") && !response[:output].include?("```\n```")
        confidence += 0.05  # Proper code formatting
      end

      [confidence, 0.1].max  # Minimum 10% confidence
    end

    def fallback_response(prompt, last_error, responses)
      @logger.error("All LLM calls failed. Last error: #{last_error}")

      # Generate a safe fallback message
      {
        success: false,
        error: "All AI models failed: #{last_error}",
        fallback: true,
        output: generate_safe_fallback(prompt),
        attempted_models: responses.map { |r| r[:model] }.compact,
        timestamp: Time.now.iso8601
      }
    end

    def generate_safe_fallback(prompt)
      # Extract task type from prompt if possible
      task_indicators = {
        'email' => "# Unable to process email task automatically\nputs 'Manual email processing required'",
        'task' => "# Unable to process task automatically\nputs 'Manual task creation required'",
        'search' => "# Unable to perform search automatically\nputs 'Manual search required'",
        'company' => "# Unable to process company data automatically\nputs 'Manual CRM update required'"
      }

      task_type = task_indicators.keys.find { |key| prompt.downcase.include?(key) }

      if task_type
        task_indicators[task_type]
      else
        "# AI assistance unavailable\nputs 'This task requires manual intervention'"
      end
    end

    def estimate_tokens(input, output)
      # Rough estimation: ~4 characters per token
      {
        input: (input.length / 4.0).ceil,
        output: (output.length / 4.0).ceil
      }
    end

    def track_success(model, response, complexity)
      @metrics[:calls][model] += 1
      @metrics[:successes][model] += 1

      # Track tokens and cost
      tokens = response[:tokens] || estimate_tokens("", response[:output])
      @metrics[:total_tokens][:input] += tokens[:input]
      @metrics[:total_tokens][:output] += tokens[:output]

      # Calculate cost
      config = MODELS[complexity]
      cost = (tokens[:input] / 1000.0 * config[:cost_per_1k][:input]) +
             (tokens[:output] / 1000.0 * config[:cost_per_1k][:output])
      @metrics[:total_cost] += cost

      @logger.info("Success with #{model}. Cost: $#{'%.4f' % cost}. Total: $#{'%.2f' % @metrics[:total_cost]}")
    end

    def track_failure(model, error)
      @metrics[:calls][model] += 1
      @metrics[:failures][model] += 1

      @logger.warn("Failure tracked for #{model}: #{error.class}")
    end

    # Custom error classes
    class RateLimitError < StandardError; end
    class TimeoutError < StandardError; end
  end
end