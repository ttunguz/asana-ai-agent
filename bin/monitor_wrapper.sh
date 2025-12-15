#!/bin/bash
echo "Starting monitor wrapper at $(date)" >> /tmp/asana_wrapper.log

# Source environment variables if file exists
if [ -f "$HOME/.asana-monitor-env" ]; then
  source "$HOME/.asana-monitor-env"
fi

/Users/tomasztunguz/.rbenv/versions/3.4.3/bin/ruby /Users/tomasztunguz/Documents/coding/asana-agent-monitor/bin/monitor.rb
EXIT_CODE=$?
echo "Monitor exited with $EXIT_CODE at $(date)" >> /tmp/asana_wrapper.log
exit $EXIT_CODE
