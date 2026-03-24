import Config

# Test configuration: mock all external services
# No real database or provider calls in tests

# Skip database connection for unit tests
# Integration tests that need the database can use fixtures or setup_all
config :bot_army_llm, BotArmyLlm.Repo,
  priv: "priv/repo"

# Use mock LLM client in tests (no real provider calls)
config :bot_army_llm, llm_client: BotArmyLlm.LlmClientMock

# Disable NATS connection in tests
config :bot_army_runtime, :nats_disabled, true
