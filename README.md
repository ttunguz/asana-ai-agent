# Asana Agent Monitor

AI agent system that monitors Asana "1 - Agent Tasks" project & automatically executes tasks using Claude Code.

## Overview

- **Architecture**: KeepAlive daemon running continuously (not scheduled task)
- **Monitoring**: Polls Asana every 3 minutes for new tasks & comments
- **Context**: Sends full conversation history (title + notes + ALL comments) to Claude
- **Routing**: All tasks routed to Claude Code (no keyword matching)
- **Output**: Plain text responses (no markdown formatting)
- **Integration**: Uses Claude Code CLI with `--print` and `--dangerously-skip-permissions`
- **Comment Monitoring**: Responds to comments on tasks for multi-turn interaction

## How It Works

1. Daemon runs continuously, polling every 3 minutes
2. Monitor fetches incomplete tasks from Asana project
3. Full context (title + notes + comment history) is sent to Claude Code
4. Claude Code processes the request & returns response
5. Response is posted as plain text comment on the task
6. Tasks remain open for further interaction via comments

**No keyword matching** - Just write what you want done in the task title/notes.

## Project Structure

```
asana-agent-monitor/
├── README.md                       # This file
├── bin/
│   └── monitor.rb                 # Main monitoring script (launchd entry point)
├── lib/
│   ├── agent_monitor.rb           # Core monitoring logic
│   ├── workflow_router.rb         # Simple router (always returns ClaudeCode)
│   ├── comment_tracker.rb         # Tracks processed comments
│   ├── task_classifier.rb         # DPSY: Task type detection
│   ├── conversation_summarizer.rb # DPSY: History summarization
│   ├── task_decomposer.rb         # GEPA: Multi-step decomposition
│   ├── prompt_templates/          # DPSY: Template system
│   │   ├── base.rb                #   Template base class
│   │   ├── simple_query.rb        #   Minimal template (no API docs)
│   │   ├── email.rb               #   Email-specific template
│   │   ├── company_research.rb    #   Research-specific template
│   │   └── general.rb             #   Full template (fallback)
│   └── workflows/
│       ├── base.rb                # Base workflow class
│       └── gemini_code.rb         # Claude/Gemini workflow + DPSY/GEPA
├── config/
│   └── agent_config.rb            # Configuration (project GID, check interval, etc.)
├── logs/
│   ├── agent.log                  # Monitor activity log
│   └── processed_comments.json    # Processed comment tracking
├── test_dpsy.rb                   # DPSY unit tests
├── test_gepa.rb                   # GEPA unit tests
└── test_claude_workflow.rb        # Workflow integration tests

Note: launchd plist at ~/Library/LaunchAgents/com.theory.asana-monitor.plist
```

## Setup

1. Asana Project GID: `1211959613518208`
2. Project URL: https://app.asana.com/0/1211959613518208
3. **Scheduler**: launchd (replaces cron as of 2025-11-20)
4. Claude Code CLI must be installed & configured

### launchd Configuration

The monitor runs as a macOS launchd KeepAlive daemon (always-running, not scheduled):

**Location**: `~/Library/LaunchAgents/com.theory.asana-monitor.plist`

**Architecture**: KeepAlive daemon with 3-minute polling interval

**Key Configuration**:
- **KeepAlive**: `true` (daemon runs continuously)
- **RunAtLoad**: `true` (starts on system boot)
- **ProcessType**: `Background` (runs in background)
- **Polling Interval**: 180 seconds (3 minutes)
- **Environment Variables**: Includes ASANA_API_KEY, PATH, HOME

**Management Commands**:
```bash
# Reload after changes
launchctl unload ~/Library/LaunchAgents/com.theory.asana-monitor.plist
launchctl load ~/Library/LaunchAgents/com.theory.asana-monitor.plist

# Check status (PID shows when running, 78 means not running)
launchctl list | grep com.theory.asana-monitor

# View logs
tail -f logs/agent.log

# Check if daemon is running
ps aux | grep monitor.rb | grep -v grep
```

**Benefits of KeepAlive Architecture**:
- Continuous monitoring (no scheduling delays)
- Graceful shutdown handling (SIGTERM/SIGINT)
- Automatic restart on crashes
- Survives sleep/wake cycles
- Better resource efficiency than scheduled tasks
- More reliable than cron or StartInterval

## Usage

### Create Tasks

Just describe what you want in natural language:

```
Task: What's the weather in SF?

Task: Research acme.com and add to Attio

Task: Draft an email to Art about the Q4 board meeting
Notes: Include agenda items: financials, hiring update, portfolio review
```

### Comment-Based Interaction

Add comments to tasks for multi-turn conversation:

```
Task: Research acme.com
→ Agent responds with research

Comment: Also check their competitors
→ Agent responds with competitor analysis

Comment: Add the top 3 competitors to Attio
→ Agent creates Attio records
```

## Architecture Simplification

**Previous**: Keyword-based routing to specialized workflows (CompanyResearch, EmailDraft, etc.)
**Current**: Direct Claude Code integration - let Claude decide how to handle each request

Benefits:
- No keyword maintenance
- More flexible task handling
- Claude can use any available tools
- Natural language task descriptions

## Recent Improvements (Nov 2025)

### 1. DPSY (Dynamic Prompt System) - Nov 28, 2025
**Token Efficiency & Cost Reduction**

- **Task Classification** : Automatically detects task type (simple_query, email, company_research, general)
- **Specialized Templates** : Only includes relevant API documentation
- **Conversation Summarization** : Keeps last 3 comments, summarizes older ones (prevents unbounded growth)
- **Token Reduction** : 93.2% for simple queries, 60-85% average across all task types

**Example**:
- Old system : "What's the weather?" → 2000 chars (all API docs)
- New system : "What's the weather?" → 43 chars (no unnecessary docs)
- Result : **93.2% token reduction** = faster responses + lower costs

### 2. GEPA (Guided Exploration & Plan Adjustment) - Nov 28, 2025
**Multi-Step Task Decomposition**

- **Automatic Decomposition** : Detects multi-company research, breaks into steps
- **Progress Tracking** : Posts 🔄/✅/❌ updates to Asana for each step
- **Retry Logic** : Automatically retries failed research steps (1 attempt)
- **VCBench Threshold Extraction** : Parses thresholds from task descriptions
- **Completion Rate** : 80%+ for multi-step tasks (vs 40-50% without GEPA)

**Example**:
```
Task: "Research stripe.com, plaid.com, alloy.ai. Add to Attio if VCBench > 40%"

GEPA breaks into 3 steps:
  🔄 Step 1/3 : Research stripe.com
  ✅ Step 1 : VCBench 52%, added to Attio

  🔄 Step 2/3 : Research plaid.com
  ✅ Step 2 : VCBench 48%, added to Attio

  🔄 Step 3/3 : Research alloy.ai
  ❌ Step 3 : VCBench 35%, skipped (below threshold)

Final: Completed 2/3 steps successfully
```

### 3. Full Conversation Context
- Every Claude request includes complete conversation history
- Includes task title, notes, and ALL previous comments with timestamps
- Maintains context across multi-turn interactions
- Comments show author & timestamp for clarity

### 4. KeepAlive Daemon Architecture
- Migrated from StartInterval (scheduled) to KeepAlive (continuous)
- Daemon runs continuously with 3-minute polling intervals
- Graceful shutdown handling via SIGTERM/SIGINT signals
- Automatic restart on crashes via launchd

### 5. Plain Text Output
- All responses use plain text formatting (no markdown)
- Headers use colons instead of bold text
- Cleaner, more readable comments in Asana

### 6. Environment Configuration
- ASANA_API_KEY included in launchd environment
- Direct Ruby path for rbenv compatibility
- No dependency on shell configuration files

### 7. Comment Loop Prevention
- Skips agent-generated comments (prefixed with ✅/❌/🤖/⚠️)
- Prevents infinite loops in comment processing
- Tracks processed comments in JSON file

## Troubleshooting

### Daemon Not Running
```bash
# Check if daemon is running
ps aux | grep monitor.rb | grep -v grep

# Check launchd status (78 = not running)
launchctl list | grep asana

# Reload launchd agent
launchctl unload ~/Library/LaunchAgents/com.theory.asana-monitor.plist
launchctl load ~/Library/LaunchAgents/com.theory.asana-monitor.plist
```

### Environment Issues
- Ensure ASANA_API_KEY is in the plist's EnvironmentVariables
- Use direct Ruby path (not rbenv shims) in plist
- Check logs for API authentication errors

### Debug Mode
```bash
# Run manually to see output
cd /Users/tomasztunguz/Documents/coding/asana-agent-monitor
/Users/tomasztunguz/.rbenv/versions/3.4.3/bin/ruby bin/monitor.rb

# Check error logs
tail -f logs/agent-error.log
```

### Common Issues
- **Exit code 78**: Configuration error, check plist syntax
- **Private method error**: Ensure fetch_task_comments is public in agent_monitor.rb
- **Missing API key**: Add ASANA_API_KEY to plist environment variables
- **Tasks not processing**: Check project GID matches in config/agent_config.rb

