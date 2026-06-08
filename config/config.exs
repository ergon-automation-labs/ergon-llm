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
  format: {BotArmyRuntime.LoggerFormatter, []},
  metadata: [:correlation_id]
