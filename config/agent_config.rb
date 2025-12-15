# config/agent_config.rb

module AgentConfig
  # Asana Configuration
  ASANA_PROJECT_GIDS = ['1211959613518208', '1203633898433121']  # Monitor 1 - Agent Tasks & Theory General
  ASANA_PROJECT_GID = '1211959613518208'  # Deprecated - use ASANA_PROJECT_GIDS
  ASANA_WORKSPACE_GID = '1203633898433095'
  ASANA_TEAM_GID = '1204407826411712'
  AGENT_NAME = 'Tomasz Tunguz'

  # Check interval (for cron)
  CHECK_INTERVAL_MINUTES = 3

  # Logging
  LOG_DIR = File.expand_path('../../logs', __FILE__)
  LOG_FILE = File.join(LOG_DIR, 'agent.log')
  LOG_LEVEL = :info  # :debug, :info, :warn, :error

  # Comment monitoring
  ENABLE_COMMENT_MONITORING = true
  COMMENT_STATE_FILE = File.join(LOG_DIR, 'processed_comments.json')
  COMMENT_MONITORING_DAYS = 7  # Only monitor tasks from last N days
  
  # Concurrency
  MAX_CONCURRENT_WORKERS = 10
  TASK_TIMEOUT = 1800 # 30 minutes per task max

  # Assignee GIDs (from TaskAPI)
  ASSIGNEES = {
    'tom' => '1203633898433084',
    'art' => '1205128325411795',
    'lauren' => '1204407991572571'
  }.freeze
end
