defmodule BotArmyLlm.Application do
  @moduledoc """
  BotArmyLlm application supervisor.

  Manages LLM bot services:
  - NATS message consumer
  - Prompt processor
  - Inference pipeline
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database connection
      BotArmyLlm.Repo,

      # NATS connection (runtime library)
      {BotArmyRuntime.NATS.Connection, []},

      # Prompt storage (in-memory + Ecto persistence)
      {BotArmyLlm.PromptStore, []},

      # Ollama health checker (probes nodes every 60s, drives routing decisions)
      {BotArmyLlm.OllamaHealthChecker, []},

      # NATS connection and consumer
      {BotArmyLlm.NATS.Consumer, []}
    ]

    opts = [strategy: :one_for_one, name: BotArmyLlm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
