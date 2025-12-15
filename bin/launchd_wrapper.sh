#!/bin/bash
# Wrapper for launchd execution
# Ensures environment is set up correctly

RUBY_PATH="/Users/tomasztunguz/.rbenv/versions/3.4.3/bin/ruby"
SCRIPT_PATH="/Users/tomasztunguz/Documents/coding/asana-agent-monitor/bin/monitor.rb"

# Log start
echo "[$(date)] Starting monitor via wrapper"

# Source environment variables if file exists
if [ -f "$HOME/.asana-monitor-env" ]; then
  source "$HOME/.asana-monitor-env"
fi

# Execute ruby script
exec "$RUBY_PATH" "$SCRIPT_PATH"
