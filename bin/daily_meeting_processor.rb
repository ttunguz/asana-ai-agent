#!/usr/bin/env ruby

require 'json'
require 'date'

class DailyMeetingProcessor
  def run
    puts "Starting daily meeting processing..."
    today = '2025-11-24' #Date.today.strftime('%Y-%m-%d')
    events_text = `ruby ~/.gemini/custom_tools_src/google_calendar/get_events.rb --date=#{today}`
    
    external_meetings = []
    
    events_text.each_line do |line|
      next unless line.start_with?('-')
      
      title_match = line.match(/- (.*) \(/)
      next unless title_match
      title = title_match[1]
      
      attendees_match = line.match(/\[(.*)\]/)
      next unless attendees_match
      
      attendees = attendees_match[1].split(',').map(&:strip)
      
      is_external = attendees.any? do |attendee|
        !attendee.end_with?('@theoryvc.com') && !attendee.end_with?('@theory.ventures') && !attendee.end_with?('resource.calendar.google.com')
      end
      
      if is_external
        external_meetings << { title: title, attendees: attendees }
      end
    end
    
    puts "Found #{external_meetings.size} external meetings:"
    external_meetings.each do |meeting|
      puts "- #{meeting[:title]}"
    end
  end
end

if __FILE__ == $0
  processor = DailyMeetingProcessor.new
  processor.run
end
