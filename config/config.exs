import Config

config :bot_army_llm, :deployment_status, "deployed"

# Load .env file for local development/testing
if File.exists?(".env") do
  File.stream!(".env")
  |> Stream.map(&String.trim_trailing/1)
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Stream.reject(&(&1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> nil
    end
  end)
end

# Ecto repositories for migrations
config :bot_army_llm, ecto_repos: [BotArmyLlm.Repo]

# Intent thresholds for LLM heartbeat decisions
config :bot_army_llm, :intent_thresholds, %{
  unsummarized_events: %{min: 20, weight: 0.6},
  idle_minutes: %{min: 120, weight: 0.4},
  random_threshold: 0.5
}

config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "[$time] [$level] $message\n",
  metadata: [
    :correlation_id,
    :source,
    :provider,
    :model,
    :latency_ms,
    :slug,
    :subject,
    :timeout_ms,
    :reason,
    :payload,
    :last_error,
    :result,
    :sample
  ]

# config/{env}.exs (test.exs, dev.exs, etc.) was never imported, so any
# override it defined (most commonly a *_test database name) was dead code —
# every mix invocation used the settings above unmodified, regardless of
# MIX_ENV. Guarded by File.exists? since not every env has its own file here.
env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end

