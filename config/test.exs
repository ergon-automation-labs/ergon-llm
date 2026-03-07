import Config

# Test configuration uses isolated test database
# Does NOT use runtime.exs environment variable overrides (compile-time only)
config :bot_army_llm, BotArmyLlm.Repo,
  database: System.get_env("BOT_ARMY_LLM_TEST_DB_NAME", "ergon_llm_test"),
  hostname: System.get_env("BOT_ARMY_LLM_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_LLM_DB_PORT", "30003")),
  username: System.get_env("BOT_ARMY_LLM_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_LLM_DB_PASSWORD", "postgres"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# Use mock LLM client in tests (no real provider calls)
config :bot_army_llm, llm_client: BotArmyLlm.LlmClientMock
