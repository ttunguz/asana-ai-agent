# lib/workflows/general_search.rb

require_relative 'base'
require 'net/http'
require 'json'
require 'uri'

module Workflows
  class GeneralSearch < Base
    def execute
      # Get search query from task notes or comment
      search_query = extract_search_query

      unless search_query
        return {
          success: false,
          error: "Could not extract search query from task",
          comment: "❌ Could not determine what to search for. Please provide a clear search request."
        }
      end

      log_info("Performing general search: #{search_query[0..80]}...")

      # Perform AI-powered search
      search_result = perform_ai_search(search_query)

      unless search_result[:success]
        return {
          success: false,
          error: search_result[:error],
          comment: "❌ Search failed: #{search_result[:error]}"
        }
      end

      # Create task for Tom with results (only if triggered by task, not comment)
      tom_task = nil
      unless from_comment?
        log_info("  Creating task with search results for Tom...")
        tom_task = create_tom_task(
          title: "Search Results: #{extract_title(search_query)}",
          notes: format_search_results(search_query, search_result)
        )
      else
        log_info("  Skipping task creation (triggered by comment)")
      end

      {
        success: true,
        comment: format_completion_comment(search_query, tom_task, search_result)
      }
    rescue => e
      log_error("General search failed: #{e.message}")

      {
        success: false,
        error: e.message,
        comment: "❌ Search failed: #{e.message}"
      }
    end

    private

    def extract_search_query
      # Get text from comment or task notes
      text = from_comment? ? @comment_text : task.notes.to_s

      # If text is empty, try task title
      text = task.name.to_s if text.strip.empty?

      # Clean up and return
      text.strip.empty? ? nil : text.strip
    end

    def extract_title(query)
      # Extract a short title from the query (first 50 chars)
      title = query[0..50]
      title += "..." if query.length > 50
      title
    end

    def perform_ai_search(query)
      # Use Perplexity AI for research-style searches (has real-time web access)
      api_url = URI('https://api.perplexity.ai/chat/completions')

      prompt = <<~PROMPT
        You are a helpful research assistant. Please answer this search query with accurate, up-to-date information:

        #{query}

        Provide a comprehensive response with:
        1. Direct answer to the query
        2. Specific recommendations (if applicable)
        3. Key details and comparisons
        4. Source references or reasoning

        Be specific and actionable. If this is a product search, include specific product names, prices, and why you recommend them.
      PROMPT

      request = Net::HTTP::Post.new(api_url)
      request['Authorization'] = "Bearer #{ENV['PERPLEXITY_API_KEY']}"
      request['Content-Type'] = 'application/json'

      request.body = {
        model: 'sonar',  # Perplexity's research model with web access
        messages: [
          {
            role: 'system',
            content: 'You are a helpful research assistant with access to current information. Provide accurate, detailed, and actionable responses.'
          },
          {
            role: 'user',
            content: prompt
          }
        ],
        max_tokens: 2048,
        temperature: 0.2  # Lower temperature for more factual responses
      }.to_json

      response = Net::HTTP.start(api_url.hostname, api_url.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end

      if response.code == '200'
        result = JSON.parse(response.body, symbolize_names: true)
        answer = result[:choices][0][:message][:content]
        citations = result[:citations] || []

        {
          success: true,
          answer: answer,
          citations: citations
        }
      else
        log_error("Perplexity API error: #{response.code} - #{response.body[0..200]}")
        { success: false, error: "AI search failed (API error #{response.code})" }
      end
    rescue => e
      log_error("AI search error: #{e.message}")
      { success: false, error: e.message }
    end

    def format_search_results(query, result)
      notes = "Search Query :\n#{query}\n\n"
      notes += "AI Research Results :\n\n"
      notes += result[:answer]
      notes += "\n\n"

      if result[:citations] && result[:citations].any?
        notes += "Sources :\n"
        result[:citations].each_with_index do |citation, i|
          notes += "#{i + 1}. #{citation}\n"
        end
      end

      notes
    end

    def format_completion_comment(query, tom_task, search_result)
      comment = "✅ Search completed : #{extract_title(query)}\n\n"

      # Include full answer with all recommendations & links
      if search_result[:answer]
        comment += search_result[:answer]
        comment += "\n\n"
      end

      # Add citations if available
      if search_result[:citations] && search_result[:citations].any?
        comment += "Sources :\n"
        search_result[:citations].each_with_index do |citation, i|
          comment += "#{i + 1}. #{citation}\n"
        end
        comment += "\n"
      end

      if tom_task
        comment += "Detailed results also saved in task for Tom."
      end

      comment
    end
  end
end
