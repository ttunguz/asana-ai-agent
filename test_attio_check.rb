require_relative '/Users/tomasztunguz/.gemini/code_mode/attio_api'

puts "Checking theoryvc.com (should exist)..."
begin
  res = AttioAPI.find(domain: 'theoryvc.com', format: :detailed)
  puts "Result Class: #{res.class}"
  puts "Result: #{res.inspect}"
rescue => e
  puts "Error: #{e.message}"
end

puts "\nChecking random-non-existent-domain-12345.com..."
begin
  res = AttioAPI.find(domain: 'random-non-existent-domain-12345.com', format: :detailed)
  puts "Result: #{res.inspect}"
rescue => e
  puts "Error: #{e.message}"
end

