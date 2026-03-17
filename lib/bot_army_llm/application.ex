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

      # Note: BotArmyRuntime.NATS.Connection is started by BotArmyRuntime.Application supervisor.
      # Do not start it here - it's already managed by the runtime library.

      # Prompt storage (in-memory + Ecto persistence)
      {BotArmyLlm.PromptStore, []},

      # Conversation storage (in-memory + Ecto persistence)
      {BotArmyLlm.ConversationStore, []},

      # Vector store for RAG (pgvector embeddings)
      {BotArmyLlm.VectorStore, []},

      # Metrics collection (in-memory counters and percentiles)
      {BotArmyLlm.Metrics, []},

      # Ollama health checker (probes nodes every 60s, drives routing decisions)
      {BotArmyLlm.OllamaHealthChecker, []},

      # NATS message consumer (depends on BotArmyRuntime.NATS.Connection being available)
      {BotArmyLlm.NATS.Consumer, []}
    ]

    opts = [strategy: :one_for_one, name: BotArmyLlm.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Setup telemetry handlers after supervisor starts
    BotArmyLlm.Telemetry.setup()

    {:ok, pid}
  end
end
