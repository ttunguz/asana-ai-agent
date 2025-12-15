# lib/prompt_templates/email.rb
# encoding: utf-8
# Template for email-related tasks (includes EmailAPI docs & encoding rules)

require_relative 'base'

module PromptTemplates
  class Email < Base
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

      1. EMAIL API (REQUIRED):
         - Use EmailAPI from ~/.gemini/code_mode/email_api.rb
         - EmailAPI.search(from: 'sender@domain.com', limit: 3, format: :concise)
         - EmailAPI.send(to: 'recipient@domain.com', subject: '...', body: '...')
         - EmailAPI.reply(to: '...', from: '...', subject: 'Re: ...', body: '...')

      2. EMAIL ENCODING:
         - Use 'notmuch show --format=json' for structured output
         - For Ruby scripts, use: .force_encoding('UTF-8').scrub
         - Prefer EmailAPI over raw notmuch commands

      3. OUTPUT REQUIREMENT:
         - If you draft or send an email, you MUST include the full text of the email (Subject, To, Body) in your final response comments.
         - Do NOT just say 'I drafted the email'. Show the draft so the user can review it.
      INSTRUCTIONS
    end
  end
end
