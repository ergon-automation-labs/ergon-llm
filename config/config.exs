import Config

# Ecto repositories for migrations
config :bot_army_llm, ecto_repos: [BotArmyLlm.Repo]

# Database configuration from Salt/Helm environment variables
config :bot_army_llm, BotArmyLlm.Repo,
  database: System.get_env("BOT_ARMY_LLM_DB_NAME", "bot_army_llm"),
  hostname: System.get_env("BOT_ARMY_LLM_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_LLM_DB_PORT", "5432")),
  username: System.get_env("BOT_ARMY_LLM_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_LLM_DB_PASSWORD", "postgres"),
  pool_size: 10
