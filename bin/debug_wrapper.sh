#!/bin/bash

# Debug wrapper for launchd - captures all output and environment
echo "=== LAUNCHD DEBUG WRAPPER STARTED ===" >> /tmp/launchd_debug.log
echo "Date: $(date)" >> /tmp/launchd_debug.log
echo "Working Directory: $(pwd)" >> /tmp/launchd_debug.log
echo "Ruby Path: $(which ruby)" >> /tmp/launchd_debug.log
echo "User: $(whoami)" >> /tmp/launchd_debug.log
echo "HOME: $HOME" >> /tmp/launchd_debug.log
echo "PATH: $PATH" >> /tmp/launchd_debug.log
echo "=== ENVIRONMENT ===" >> /tmp/launchd_debug.log
env | sort >> /tmp/launchd_debug.log
echo "=== CHECKING API KEY ===" >> /tmp/launchd_debug.log
if [ -z "$ASANA_API_KEY" ]; then
    echo "ERROR: ASANA_API_KEY is not set!" >> /tmp/launchd_debug.log
else
    echo "ASANA_API_KEY is set (length: ${#ASANA_API_KEY})" >> /tmp/launchd_debug.log
fi
echo "=== STARTING RUBY DAEMON ===" >> /tmp/launchd_debug.log

# Try to source the user's shell config to get environment variables
if [ -f ~/.zshrc ]; then
    echo "Sourcing ~/.zshrc" >> /tmp/launchd_debug.log
    source ~/.zshrc
elif [ -f ~/.bash_profile ]; then
    echo "Sourcing ~/.bash_profile" >> /tmp/launchd_debug.log
    source ~/.bash_profile
fi

# Now run the actual daemon
exec /Users/tomasztunguz/.rbenv/versions/3.4.3/bin/ruby /Users/tomasztunguz/Documents/coding/asana-agent-monitor/bin/monitor.rb 2>&1 | tee -a /tmp/launchd_debug.log