# lib/workflows/company_research.rb

require_relative 'base'
require '/Users/tomasztunguz/.gemini/code_mode/attio_api'
require '/Users/tomasztunguz/.gemini/code_mode/research_api'
require '/Users/tomasztunguz/.gemini/code_mode/notion_api'

module Workflows
  class CompanyResearch < Base
    def execute
      # Extract domain (from comment text if triggered by comment, otherwise from task)
      if from_comment? && comment_text
        domain = extract_domain(comment_text)
      else
        domain = extract_domain(task.name) || extract_domain(task.notes)
      end

      if domain.nil?
        return {
          success: false,
          error: "Could not extract domain from #{from_comment? ? 'comment' : 'task'}",
          comment: "❌ Could not find company domain in #{from_comment? ? 'comment' : 'task title or notes'}"
        }
      end

      log_info("Researching company: #{domain}")

      # Step 1: Add to Attio
      log_info("  Adding #{domain} to Attio...")
      attio_result = AttioAPI.find_or_create(
        domain: domain,
        name: extract_company_name(domain),
        source: 'agent',
        enrich: false
      )

      unless attio_result[:success]
        return {
          success: false,
          error: "Failed to add to Attio: #{attio_result[:error]}",
          comment: "❌ Failed to add company to Attio"
        }
      end

      company_name = attio_result[:name] || domain

      # Step 2: Run VCBench analysis
      log_info("  Running VCBench analysis...")
      vcbench_result = ResearchAPI.evaluate_introduction(domain: domain)

      # Step 3: Get Harmonic metrics
      log_info("  Fetching Harmonic metrics...")
      harmonic_result = ResearchAPI.harmonic_company(domain: domain, format: :table)

      # Step 4: Prepend to Notion (if VCBench succeeded)
      if vcbench_result[:success]
        log_info("  Prepending research to Notion...")
        NotionAPI.prepend(
          domain: domain,
          content: format_research_summary(domain, vcbench_result, harmonic_result)
        )
      end

      # Step 5: Create task for Tom (only if triggered by task, not comment)
      tom_task = nil
      unless from_comment?
        log_info("  Creating review task for Tom...")
        tom_task = create_tom_task(
          title: "Review #{company_name} research",
          notes: format_tom_task_notes(domain, vcbench_result, harmonic_result, attio_result)
        )
      else
        log_info("  Skipping task creation (triggered by comment)")
      end

      {
        success: true,
        comment: format_completion_comment(domain, vcbench_result, tom_task)
      }
    rescue => e
      log_error("Research failed: #{e.message}")
      log_error(e.backtrace.join("\n"))

      {
        success: false,
        error: e.message,
        comment: "❌ Research failed: #{e.message}"
      }
    end

    private

    def extract_company_name(domain)
      # Simple heuristic: capitalize domain name without TLD
      domain.split('.').first.capitalize
    end

    def format_research_summary(domain, vcbench, harmonic)
      # Format plain text for Notion
      summary = "Research Summary (Agent)\n\n"

      if vcbench[:success]
        summary += "VCBench Analysis :\n"
        summary += "- Recommendation : #{vcbench[:vcbench][:recommendation]}\n"
        summary += "- Score : #{vcbench[:vcbench][:composite_score]}\n\n"
      end

      if harmonic[:success] && harmonic[:markdown]
        summary += "Harmonic Metrics :\n"
        summary += harmonic[:markdown] + "\n\n"
      end

      summary += "---\n\n"
      summary
    end

    def format_tom_task_notes(domain, vcbench, harmonic, attio)
      notes = "Full research on #{domain} completed by agent.\n\n"

      if vcbench[:success]
        notes += "VCBench Decision : #{vcbench[:vcbench][:recommendation]}\n"
        notes += "Score : #{vcbench[:vcbench][:composite_score]}\n\n"
        notes += vcbench[:decision_summary] + "\n\n"
      end

      if harmonic[:success] && harmonic[:markdown]
        notes += "Traction Metrics :\n"
        notes += harmonic[:markdown] + "\n\n"
      end

      if attio[:success] && attio[:notion_url]
        notes += "Notion : #{attio[:notion_url]}\n"
      end

      notes += "\nDomain : #{domain}"
      notes
    end

    def format_completion_comment(domain, vcbench, tom_task)
      comment = "✅ Research complete for #{domain}\n\n"

      if vcbench[:success]
        comment += "VCBench : #{vcbench[:vcbench][:recommendation]} (#{vcbench[:vcbench][:composite_score]})\n"
      end

      if tom_task
        comment += "\nReview task created for Tom."
      end

      comment
    end
  end
end
