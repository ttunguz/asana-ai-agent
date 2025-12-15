require_relative '/Users/tomasztunguz/.gemini/code_mode/attio_api'
require 'uri'

# Read the file
file_path = File.expand_path("~/Documents/yc_w25.md")
puts "Reading #{file_path}..."
content = File.read(file_path)

# Extract domains
puts "Extracting domains..."

# Try primary pattern (found in typical lines)
raw_urls = content.scan(/<div>\s*<strong>\s*<a\s+href="(https?:\/\/[^"]+)"\s+target="_blank">/).flatten

if raw_urls.empty?
  puts "Primary regex failed. Trying fallback pattern..."
  raw_urls = content.scan(/href="(https?:\/\/[^"]+)"\s+target="_blank"/).flatten
  
  # Filter unwanted domains
  raw_urls.reject! do |u|
    u.include?("ycombinator.com") || 
    u.include?("bookface") || 
    u.include?("linkedin.com") || 
    u.include?("twitter.com") || 
    u.include?("x.com") || 
    u.include?("youtube.com") ||
    u.include?("cloudflare") ||
    u.include?("font-awesome") ||
    u.include?("googleapis")
  end
end

puts "Found #{raw_urls.size} raw URLs."

domains = raw_urls.map do |url|
  begin
    uri = URI.parse(url)
    host = uri.host
    host = host.sub(/^www\./, '').downcase if host
    host
  rescue
    nil
  end
end.compact.uniq

# Filter out empty
domains.reject! { |d| d.nil? || d.empty? || !d.include?('.') }

puts "Identified #{domains.size} unique domains to check."

# Chunk domains for 5 processes
num_processes = 5
chunk_size = (domains.size / num_processes.to_f).ceil
chunks = domains.each_slice(chunk_size).to_a

puts "Starting check with #{chunks.size} processes..."

pids = []

chunks.each_with_index do |chunk, index|
  pid = fork do
    # Child process
    found_in_batch = []
    missing_in_batch = []
    
    chunk.each do |domain|
      begin
        # Use ids_only format for speed
        AttioAPI.find(domain: domain, format: :ids_only)
        found_in_batch << domain
        print "."
        $stdout.flush
      rescue => e
        if e.message.include?("not found")
           missing_in_batch << domain
           print "x"
        else
           missing_in_batch << domain # treat error as missing
           print "E"
        end
        $stdout.flush
      end
    end
    
    # Write results to temp files
    File.write("batch_#{index}_found.txt", found_in_batch.join("\n"))
    File.write("batch_#{index}_missing.txt", missing_in_batch.join("\n"))
    exit(0)
  end
  pids << pid
end

# Wait for all processes
pids.each { |pid| Process.wait(pid) }

puts "\n\nProcesses finished. Aggregating results..."

# Aggregate
all_found = []
all_missing = []

chunks.each_index do |index|
  found_file = "batch_#{index}_found.txt"
  missing_file = "batch_#{index}_missing.txt"
  
  if File.exist?(found_file)
    all_found.concat(File.read(found_file).split("\n"))
    File.delete(found_file)
  end
  
  if File.exist?(missing_file)
    all_missing.concat(File.read(missing_file).split("\n"))
    File.delete(missing_file)
  end
end

all_found.uniq!
all_missing.uniq!

puts "\n--- Results ---"
puts "Total Checked: #{domains.size}"
puts "✅ Found in Attio: #{all_found.size}"
puts "❌ Missing/Not Found: #{all_missing.size}"

# Write missing to file
output_file = "yc_w25_missing.txt"
File.write(output_file, all_missing.join("\n"))
puts "\n📝 Missing companies list saved to #{output_file}"

if all_missing.any?
  puts "\nSample missing: #{all_missing.first(5).join(', ')}"
end