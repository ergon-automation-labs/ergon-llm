import Config

# This file is loaded at runtime (not at compile time).
# It reads environment variables and configures the application.

# Database configuration - read at runtime from environment variables
config :bot_army_llm, BotArmyLlm.Repo,
  database: System.get_env("BOT_ARMY_LLM_DB_NAME") || System.get_env("DATABASE_NAME") || "ergon_llm_dev",
  hostname: System.get_env("BOT_ARMY_LLM_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port: String.to_integer(System.get_env("BOT_ARMY_LLM_DB_PORT") || System.get_env("DATABASE_PORT") || "30003"),
  username: System.get_env("BOT_ARMY_LLM_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("BOT_ARMY_LLM_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") || "postgres",
  pool_size: 10

# NATS configuration for bot_army_runtime
# Parses NATS_HOST and NATS_PORT from environment variables (set by Salt)
nats_host = System.get_env("NATS_HOST") || "localhost"
nats_port = String.to_integer(System.get_env("NATS_PORT") || "4222")

config :bot_army_runtime, :nats,
  servers: [{nats_host, nats_port}],
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000

