import Config

# This file runs when the VM starts (release, mix, tests), not when the release is compiled.
# Repo and :http_proxy must live here so `mix release` + `LlmProxy.Release.migrate()` on
# production use BOT_ARMY_LLM_DB_* from launchd/env — values in config.exs would be baked in
# at compile time with dev defaults (e.g. ergon_llm_dev).

db_name =
  System.get_env("BOT_ARMY_LLM_DB_NAME") ||
    System.get_env("DATABASE_NAME") ||
    case config_env() do
      :prod -> "ergon_llm"
      _ -> "ergon_llm_dev"
    end

config :bot_army_llm, BotArmyLlm.Repo,
  priv: "priv/repo",
  database: db_name,
  hostname:
    System.get_env("BOT_ARMY_LLM_DB_HOST") || System.get_env("DATABASE_HOST", "localhost"),
  port:
    String.to_integer(
      System.get_env("BOT_ARMY_LLM_DB_PORT") || System.get_env("DATABASE_PORT", "30003")
    ),
  username: System.get_env("BOT_ARMY_LLM_DB_USER") || System.get_env("DATABASE_USER", "postgres"),
  password:
    System.get_env("BOT_ARMY_LLM_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD", "postgres"),
  pool_size: System.get_env("BOT_POOL_SIZE", "20") |> String.to_integer(),

# Test sets :http_proxy below; do not override here.
if config_env() != :test do
  config :bot_army_llm, :http_proxy,
    enabled: System.get_env("BOT_ARMY_LLM_HTTP_ENABLED") in ~w(1 true yes),
    port: String.to_integer(System.get_env("BOT_ARMY_LLM_HTTP_PORT") || "39891"),
    ip: {0, 0, 0, 0},
    auth_token: System.get_env("BOT_ARMY_LLM_HTTP_TOKEN")
end

# NATS configuration for bot_army_runtime
nats_host = System.get_env("NATS_HOST") || "localhost"
nats_port = String.to_integer(System.get_env("NATS_PORT") || "4223")

config :bot_army_library_runtime, :nats,
  servers: [{nats_host, nats_port}],
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000
