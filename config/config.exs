import Config

config :bot_army_llm, :deployment_status, "deployed"
# Load .env for local development — never under :test. `.env` is gitignored and carries
# `NATS_PORT=4222`; `System.put_env/2` writes the VM's own env table, which is exactly
# what `Connection.pick_servers/2` reads (opts -> app config -> env -> default), so a
# shell-exported `NATS_PORT=42991` is overwritten *inside the VM* and cannot save a run.
# On 2026-10-13 a `mix test` in `bot_army_fitness` published a real
# `gossip.social.invite` into gtd's production log that way.
# docs/runbooks/KNOWN_ISSUE_DOTENV_IN_VM_OVERRIDES_THE_TEST_BROKER.md
if config_env() != :test and File.exists?(".env") do
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

