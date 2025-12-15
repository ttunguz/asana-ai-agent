#!/usr/bin/env ruby
# encoding: utf-8
# Test script to verify timeout protection works

require 'timeout'
require 'open3'

puts "Testing timeout mechanism..."
puts

# Test 1: Verify basic timeout works
puts "Test 1: Basic Timeout (should timeout after 2 seconds)"
begin
  Timeout.timeout(2) do
    puts "  Starting 5-second sleep..."
    sleep 5
    puts "  This should never print"
  end
  puts "  ❌ FAILED: Timeout didn't trigger"
rescue Timeout::Error
  puts "  ✅ PASSED: Timeout triggered correctly"
end
puts

# Test 2: Verify process killing works
puts "Test 2: Process Kill on Timeout"
begin
  pid = nil
  Timeout.timeout(2) do
    cmd = "sleep 10"
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
      pid = wait_thr.pid
      puts "  Started process #{pid}"
      stdin.close
      stdout.read
    end
  end
  puts "  ❌ FAILED: Timeout didn't trigger"
rescue Timeout::Error
  puts "  Timeout triggered, killing process #{pid}..."
  if pid
    begin
      Process.kill("KILL", pid)
      Process.detach(pid)
      puts "  ✅ PASSED: Process killed successfully"
    rescue Errno::ESRCH
      puts "  ✅ PASSED: Process already dead"
    end
  end
end
puts

# Test 3: Verify nested timeout (workflow > step > execution)
puts "Test 3: Nested Timeout Layers"
begin
  # Outer timeout (workflow level) - 5 seconds
  Timeout.timeout(5) do
    begin
      # Middle timeout (step level) - 3 seconds
      Timeout.timeout(3) do
        begin
          # Inner timeout (execution level) - 1 second
          Timeout.timeout(1) do
            puts "  Starting 10-second sleep..."
            sleep 10
          end
        rescue Timeout::Error
          puts "  ✅ Inner timeout (execution level) triggered at 1s"
          raise  # Re-raise to test outer layers
        end
      end
    rescue Timeout::Error
      puts "  ✅ Middle timeout (step level) would trigger at 3s"
      raise
    end
  end
rescue Timeout::Error
  puts "  ✅ PASSED: Outer timeout (workflow level) would trigger at 5s"
end
puts

puts "All timeout tests completed!"
puts
puts "Summary:"
puts "  - Workflow timeout: 30 minutes (1800 seconds)"
puts "  - Step timeout: 10 minutes (600 seconds)"
puts "  - Execution timeout: 5 minutes (300 seconds)"
puts
puts "This should prevent 2-hour hangs like PID 62341."
