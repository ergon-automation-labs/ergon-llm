import Config

# Test configuration: mock all external services
# No real database or provider calls in tests

# Do not start Ecto Repo in tests — avoids Postgrex connection errors when
# ergon_llm_dev (or configured DB) is absent. PromptStore/ConversationStore
# already recover with empty state. Set BOT_ARMY_LLM_TEST_REPO=1 to run with a
# real database (e.g. integration tests).
config :bot_army_llm, :start_repo,
  System.get_env("BOT_ARMY_LLM_TEST_REPO") in ~w(1 true yes)

# Repo connection comes from config/runtime.exs (same as dev/prod releases).

# Use mock LLM client in tests (no real provider calls)
config :bot_army_llm, llm_client: BotArmyLlm.LlmClientMock

# Disable NATS connection in tests
config :bot_army_library_runtime, :nats_disabled, true

# HTTP proxy off in tests (no Bandit/Finch listeners)
config :bot_army_llm, :http_proxy,
  enabled: false,
  port: 39_891,
  ip: {127, 0, 0, 1},
  auth_token: nil
