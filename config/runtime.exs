import Config

# This file runs when the VM starts (release, mix, tests), not when the release is compiled.

if config_env() != :test do
  alias BotArmyLibraryRuntime.Ecto.RuntimeDbConfig

  db_config =
    RuntimeDbConfig.resolve("BOT_ARMY_LLM", database: "ergon_llm", port: 30006)

  config :bot_army_llm,
         BotArmyLlm.Repo,
         Keyword.merge(
           [priv: "priv/repo"],
           Keyword.put(db_config, :pool_size, RuntimeDbConfig.pool_size("BOT_ARMY_LLM", 5))
         )
end

# Test sets :http_proxy below; do not override here.
if config_env() != :test do
  config :bot_army_llm, :http_proxy,
    enabled:
      BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_LLM_HTTP_ENABLED", "false")
      |> String.downcase()
      |> then(&(&1 in ~w(1 true yes))),
    port:
      BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_LLM_HTTP_PORT", "39891")
      |> String.to_integer(),
    ip: {0, 0, 0, 0},
    auth_token: BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_LLM_HTTP_TOKEN")
end

# NATS configuration for bot_army_runtime
if config_env() != :test do
  nats_host = BotArmyLibraryRuntime.ConfigLoader.get("NATS_HOST", "localhost")

  nats_port =
    BotArmyLibraryRuntime.ConfigLoader.get("NATS_PORT", "4223") |> String.to_integer()

  config :bot_army_library_runtime, :nats,
    servers: [{nats_host, nats_port}],
    ping_interval: 30_000,
    max_reconnect_attempts: 10,
    reconnect_delay_ms: 1000
end
