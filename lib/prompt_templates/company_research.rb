# lib/prompt_templates/company_research.rb
# encoding: utf-8
# Template for company research tasks (includes AttioAPI, ResearchAPI docs)

require_relative 'base'

module PromptTemplates
  class CompanyResearch < Base
    def build
      parts = []
      parts << task_context
      parts << conversation_history unless comments.empty?
      parts << latest_request
      parts << "\n\n" + instructions

      parts.join.strip
    end

    private

    def instructions
      <<~INSTRUCTIONS
      IMPORTANT INSTRUCTIONS:

      1. CODE MODE APIs (REQUIRED):

         CRITICAL: When asked to ADD or CREATE companies in Attio, you MUST generate the Ruby code to execute the API calls.
         Do not just describe what should be done.

         - AttioAPI : Find, create, update companies in CRM
           require_relative '/Users/tomasztunguz/.gemini/code_mode/attio_api'
           AttioAPI.find_or_create(domain: 'startup.com', name: 'Startup Inc', source: 'referral')
           → Use this to ADD companies to Attio (required for "add to attio" tasks)

           AttioAPI.find(domain: 'acme.com', format: :detailed)
           → Use this to CHECK if company exists

         - ResearchAPI : Company analysis & evaluation
           require_relative '/Users/tomasztunguz/.gemini/code_mode/research_api'
           ResearchAPI.quick_lookup(domain: 'acme.com')
           ResearchAPI.harmonic_company(domain: 'acme.com', format: :table)
           ResearchAPI.vcbench_analyze(domain: 'acme.com')

         - NotionAPI : Manage Notion pages
           require_relative '/Users/tomasztunguz/.gemini/code_mode/notion_api'
           NotionAPI.append(domain: 'acme.com', content: 'Research notes...')
           NotionAPI.search(query: 'meeting notes', limit: 5)

         - Market Map Requests :
           
           If you are executing via Claude, USE THE THEORY MCP TOOLS:
           - mcp__theorymcp__create_market_map(domains: [...], market_name: '...', owners: ['tt@theoryvc.com'], status: 'Active', thesis: 'GenAI')
           - mcp__theorymcp__add_company_to_market_map(market_map_notion_link: '...', new_company_domains: [...])
           
           If MCP tools are not available (Gemini), use manual instructions:
           1. Use AttioAPI to add companies to Attio CRM
           2. Generate market analysis content (optional)
           3. Provide instructions for the user to execute in Claude Code

         Your response MUST include:
           - The Ruby code block to execute the actions (or XML for MCP tools)
           - A summary of the actions taken

      2. SAFETY:
         - DO NOT run 'find' on entire home directory - causes system hangs
         - Only search specific subdirectories if needed
         - Prefer using 'Glob' or 'ls' for file discovery
      INSTRUCTIONS
    end
  end
end
