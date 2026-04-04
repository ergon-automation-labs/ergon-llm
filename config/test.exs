import Config

# Test configuration: mock all external services
# No real database or provider calls in tests

# Repo connection comes from config/runtime.exs (same as dev/prod releases).

# Use mock LLM client in tests (no real provider calls)
config :bot_army_llm, llm_client: BotArmyLlm.LlmClientMock

# Disable NATS connection in tests
config :bot_army_runtime, :nats_disabled, true

# HTTP proxy off in tests (no Bandit/Finch listeners)
config :bot_army_llm, :http_proxy,
  enabled: false,
  port: 39_891,
  ip: {127, 0, 0, 1},
  auth_token: nil
