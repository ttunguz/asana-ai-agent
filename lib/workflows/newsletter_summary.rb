# lib/workflows/newsletter_summary.rb

require_relative 'base'
require '/Users/tomasztunguz/.gemini/code_mode/email_api'
require 'date'

module Workflows
  class NewsletterSummary < Base
    def execute
      log_info("Processing newsletter summary request...")

      # Determine date range (default: last 7 days)
      days = extract_days_from_task || 7
      start_date = Date.today - days

      log_info("  Processing newsletters from last #{days} days...")

      # Fetch recent newsletter emails
      newsletters = fetch_newsletters(days)

      if newsletters.empty?
        return {
          success: true,
          comment: "✅ No newsletters found in the last #{days} days."
        }
      end

      log_info("  Found #{newsletters.size} newsletters")

      # Generate summary
      summary = generate_newsletter_summary(newsletters, days)

      # Create digest task for Tom (only if triggered by task, not comment)
      tom_task = nil
      unless from_comment?
        log_info("  Creating digest task for Tom...")
        tom_task = create_tom_task(
          title: "Newsletter digest - #{start_date} to #{Date.today}",
          notes: summary
        )
      else
        log_info("  Skipping task creation (triggered by comment)")
      end

      comment = "✅ Newsletter digest created (#{newsletters.size} newsletters processed)"
      comment += "\n\nDigest task created for Tom." if tom_task

      {
        success: true,
        comment: comment
      }
    rescue => e
      log_error("Newsletter summary failed: #{e.message}")

      {
        success: false,
        error: e.message,
        comment: "❌ Failed to process newsletters: #{e.message}"
      }
    end

    private

    def extract_days_from_task
      # Look for patterns like "last 7 days", "past week", "this week"
      text = "#{task.name} #{task.notes}".downcase

      # Try to extract number of days
      if text.match?(/last\s+(\d+)\s+days?/)
        text.match(/last\s+(\d+)\s+days?/)[1].to_i
      elsif text.match?(/past\s+(\d+)\s+days?/)
        text.match(/past\s+(\d+)\s+days?/)[1].to_i
      elsif text.match?(/this week/)
        7
      elsif text.match?(/this month/)
        30
      else
        nil
      end
    end

    def fetch_newsletters(days)
      # Use EmailAPI to search for newsletter-tagged emails
      # For now, use a simple heuristic: emails with "newsletter" in subject
      result = EmailAPI.search(
        query: "subject:newsletter OR subject:digest OR subject:roundup",
        limit: 20,
        format: :concise
      )

      if result[:success] && result[:data]
        # Filter by date
        cutoff = Date.today - days
        result[:data].select do |email|
          email_date = Date.parse(email[:date]) rescue Date.today
          email_date >= cutoff
        end
      else
        []
      end
    rescue => e
      log_error("Failed to fetch newsletters: #{e.message}")
      []
    end

    def generate_newsletter_summary(newsletters, days)
      summary = "Newsletter Digest\n\n"
      summary += "Period : Last #{days} days\n"
      summary += "Count : #{newsletters.size} newsletters\n\n"
      summary += "---\n\n"

      newsletters.each_with_index do |newsletter, index|
        summary += "#{index + 1}. #{newsletter[:subject]}\n"
        summary += "From : #{newsletter[:from]}\n"
        summary += "Date : #{newsletter[:date]}\n\n"

        # Add preview if available
        if newsletter[:preview]
          summary += "Preview :\n#{newsletter[:preview]}\n\n"
        end

        summary += "---\n\n"
      end

      summary += "\nNote : Full AI-powered extraction of company mentions & insights coming in future iteration."
      summary
    end
  end
end
