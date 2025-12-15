#!/usr/bin/env ruby
# frozen_string_literal: true

# TheoryMCP Bridge - Creates instructions for Claude Code to execute theorymcp commands
# Since theorymcp is only accessible from Claude Code, this bridge generates
# the exact commands that should be run in Claude Code

module Workflows
  class TheoryMCPBridge

    def self.generate_market_map_instructions(task_name, domains, options = {})
      domains_array = Array(domains).map { |d| "\"#{d}\"" }.join(", ")

      instructions = <<~INSTRUCTIONS
      ## 🤖 Market Map Request - Requires Claude Code Execution

      **Task:** #{task_name}
      **Domains to analyze:** #{Array(domains).join(", ")}

      ### Instructions for Claude Code:

      1. **Create a new market map:**
      ```
      Use the mcp__theorymcp__create_market_map tool with:
      - domains: [#{domains_array}]
      - market_name: "#{task_name}"
      - owners: ["tt@theoryvc.com"]
      - status: "Active"
      - thesis: "GenAI"
      ```

      2. **Or add to existing market map (if you have the Notion URL):**
      ```
      Use the mcp__theorymcp__add_company_to_market_map tool with:
      - market_map_notion_link: "[NOTION_URL]"
      - new_company_domains: [#{domains_array}]
      ```

      3. **After creating, update market map content:**
      ```
      Use the mcp__theorymcp__update_market_map_content tool with:
      - market_map_notion_link: "[NOTION_URL from step 1]"
      - update_context: "Additional research and analysis for #{task_name}"
      ```

      ### Alternative: Use Claude Code directly

      Open Claude Code and run:
      ```xml
      <invoke name="mcp__theorymcp__create_market_map">
        <parameter name="domains">[#{domains_array}]</parameter>
        <parameter name="market_name">#{task_name}</parameter>
        <parameter name="owners">["tt@theoryvc.com"]</parameter>
        <parameter name="status">Active</parameter>
        <parameter name="thesis">GenAI</parameter>
      </invoke>
      ```

      ### Why Manual Execution?
      The Theory MCP server provides superior Notion integration and automatic background processing
      that isn't available through the standalone MarketMapAPI. This ensures proper workflow automation
      and content enrichment in your Notion workspace.

      ---
      ⚠️ **Note:** This task requires Theory MCP which is only accessible from Claude Code, not from this agent.
      Please copy the above instructions to Claude Code for execution.
      INSTRUCTIONS

      instructions
    end

    def self.generate_add_to_map_instructions(notion_url, new_domains)
      domains_array = Array(new_domains).map { |d| "\"#{d}\"" }.join(", ")

      instructions = <<~INSTRUCTIONS
      ## 🤖 Add Companies to Market Map - Requires Claude Code

      **Market Map:** #{notion_url}
      **New Companies:** #{Array(new_domains).join(", ")}

      ### Execute in Claude Code:

      ```xml
      <invoke name="mcp__theorymcp__add_company_to_market_map">
        <parameter name="market_map_notion_link">#{notion_url}</parameter>
        <parameter name="new_company_domains">[#{domains_array}]</parameter>
      </invoke>
      ```

      This will:
      1. Link the companies to the market map
      2. Run comprehensive analysis in the background
      3. Update the Notion page with enriched content

      ---
      ⚠️ **Note:** Theory MCP required - execute in Claude Code
      INSTRUCTIONS

      instructions
    end

    def self.check_if_market_map_request(task_description)
      market_map_keywords = [
        'market map',
        'market mapping',
        'create market map',
        'add to market map',
        'theorymcp',
        'theory mcp',
        'market analysis',
        'competitive landscape'
      ]

      description_lower = task_description.to_s.downcase
      market_map_keywords.any? { |keyword| description_lower.include?(keyword) }
    end

    def self.extract_domains_from_text(text)
      # Extract domains that look like company domains
      potential_domains = text.scan(/\b[a-z0-9][\w-]*\.(?:com|ai|io|co|app|dev|tech|net|org)\b/i)
      potential_domains.uniq.map(&:downcase)
    end
  end
end