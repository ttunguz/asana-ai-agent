# lib/workflows/article_summary.rb
# encoding: utf-8

require_relative 'base'
require 'open3'

module Workflows
  class ArticleSummary < Base
    def execute
      # Check task name first, then notes for URL
      url = extract_url_from_task

      unless url
        return {
          success: false,
          error: "No URL found in task name or notes",
          comment: "❌ Could not find URL to summarize. Please include a URL in the task title or notes."
        }
      end

      log_info("Summarizing article: #{url}")

      # Fetch & summarize article
      summary_result = fetch_and_summarize(url)

      unless summary_result[:success]
        return {
          success: false,
          error: summary_result[:error],
          comment: "❌ Failed to summarize article: #{summary_result[:error]}"
        }
      end

      # Create task for Tom (only if triggered by task, not comment)
      tom_task = nil
      unless from_comment?
        log_info("  Creating read task for Tom...")
        tom_task = create_tom_task(
          title: "Read: #{summary_result[:title]}",
          notes: format_tom_task_notes(url, summary_result)
        )
      else
        log_info("  Skipping task creation (triggered by comment)")
      end

      {
        success: true,
        comment: format_completion_comment(summary_result, tom_task)
      }
    rescue => e
      log_error("Article summary failed: #{e.message}")

      {
        success: false,
        error: e.message,
        comment: "❌ Failed to summarize article: #{e.message}"
      }
    end

    private

    def extract_url_from_task
      # Try to extract URL from task name first
      url = extract_url(task.name)
      return normalize_url(url) if url

      # Fall back to notes field
      if task.notes && !task.notes.strip.empty?
        url = extract_url(task.notes)
        return normalize_url(url) if url
      end

      nil
    end

    def extract_url(text)
      return nil if text.nil? || text.strip.empty?

      # Look for URLs in the text (http/https URLs)
      url_match = text.match(%r{https?://[^\s]+})
      return url_match[0] if url_match

      # If the entire text looks like a domain/URL (no spaces, contains dots)
      stripped = text.strip
      if stripped.match?(/^[^
\s]+\.[^\s]+$/) && !stripped.match?(/\s/)
        return stripped
      end

      nil
    end

    def normalize_url(url)
      return nil if url.nil?
      url.start_with?('http') ? url : "https://#{url}"
    end

    def fetch_and_summarize(url)
      # Use curl to fetch article content
      stdout, stderr, status = Open3.capture3("curl", "-s", "-L", url)

      unless status.success?
        return { success: false, error: "Failed to fetch URL" }
      end

      # Force UTF-8 encoding and scrub invalid bytes
      html_content = stdout.force_encoding('UTF-8').scrub('')

      # Extract title and text content
      title = extract_title(html_content) || url
      text_content = extract_text_content(html_content)

      if text_content.nil? || text_content.strip.empty?
        return { success: false, error: "No text content found" }
      end

      # Generate AI summary using Claude
      ai_result = generate_ai_summary(title, text_content, url)

      unless ai_result[:success]
        return ai_result
      end

      {
        success: true,
        title: title,
        summary: ai_result[:summary],
        key_points: ai_result[:key_points],
        relevance: ai_result[:relevance]
      }
    end

    def extract_title(html)
      # Simple regex to extract <title> tag
      match = html.match(/<title>(.*?)<\/title>/i)
      if match
        # Clean up common patterns
        title = match[1].strip
        # Remove common suffixes
        title.gsub(/\s*[|\-–—]\s*.+$/, '').strip
      else
        nil
      end
    end

    def extract_text_content(html)
      # Remove script and style tags
      text = html.gsub(/<script[^>]*>.*?<\/script>/im, '')
      text = text.gsub(/<style[^>]*>.*?<\/style>/im, '')

      # Remove HTML tags
      text = text.gsub(/<[^>]+>/, ' ')

      # Decode HTML entities
      text = text.gsub(/&nbsp;/, ' ')
      text = text.gsub(/&amp;/, '&')
      text = text.gsub(/&lt;/, '<')
      text = text.gsub(/&gt;/, '>')
      text = text.gsub(/&quot;/, '"')

      # Clean up whitespace
      text = text.gsub(/\s+/, ' ').strip

      # Truncate to reasonable length for API (first ~8000 chars = ~2000 tokens)
      text[0...8000]
    end

    def generate_ai_summary(title, content, url)
      require 'net/http'
      require 'json'
      require 'uri'

      # Use OpenAI API (more reliable than Anthropic for this use case)
      api_url = URI('https://api.openai.com/v1/chat/completions')

      prompt = <<~PROMPT
        You are analyzing an article for Tom Tunguz, a VC at Theory Ventures focusing on data infrastructure, AI, and vertical software.

        Article Title: #{title}
        URL: #{url}

        Please provide:
        1. A concise 3-5 sentence summary
        2. 5-7 key takeaways or insights
        3. Why this matters for venture investing (1-2 sentences)

        Format your response as JSON:
        {
          "summary": "...",
          "key_points": ["point 1", "point 2", ...],
          "relevance": "why this matters for VC..."
        }

        Article content:
        #{content}
      PROMPT

      request = Net::HTTP::Post.new(api_url)
      request['Authorization'] = "Bearer #{ENV['OPENAI_API_KEY']}"
      request['Content-Type'] = 'application/json'

      request.body = {
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: 'You are a helpful AI assistant that summarizes articles for venture capitalists. Always respond with valid JSON.'
          },
          {
            role: 'user',
            content: prompt
          }
        ],
        response_format: { type: 'json_object' },
        max_tokens: 1024
      }.to_json

      response = Net::HTTP.start(api_url.hostname, api_url.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end

      if response.code == '200'
        result = JSON.parse(response.body, symbolize_names: true)
        text_content = result[:choices][0][:message][:content]

        # Parse JSON response
        parsed = JSON.parse(text_content, symbolize_names: true)
        {
          success: true,
          summary: parsed[:summary],
          key_points: parsed[:key_points],
          relevance: parsed[:relevance]
        }
      else
        log_error("OpenAI API error: #{response.code} - #{response.body[0..200]}")
        { success: false, error: "AI summarization failed" }
      end
    rescue => e
      log_error("AI summary error: #{e.message}")
      { success: false, error: e.message }
    end

    def format_tom_task_notes(url, summary_result)
      notes = "Article : #{url}\n\n"
      notes += "Title : #{summary_result[:title]}\n\n"
      notes += "Summary :\n#{summary_result[:summary]}\n\n"

      if summary_result[:key_points]
        notes += "Key Points :\n"
        summary_result[:key_points].each do |point|
          notes += "- #{point}\n"
        end
        notes += "\n"
      end

      if summary_result[:relevance]
        notes += "Why This Matters :\n#{summary_result[:relevance]}\n\n"
      end

      notes += "Original URL : #{url}"
      notes
    end

    def format_completion_comment(summary_result, tom_task)
      comment = "✅ Article summarized: #{summary_result[:title]}\n\n"

      if tom_task
        comment += "Read task created for Tom."
      end

      comment
    end
  end
end

