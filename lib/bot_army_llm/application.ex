defmodule BotArmyLlm.Application do
  @moduledoc """
  BotArmyLlm application supervisor.

  Manages LLM bot services:
  - NATS message consumer
  - Prompt processor
  - Inference pipeline
  """

  use Application

  @env Mix.env()

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
      # Not started in tests to avoid connecting to real NATS
      {BotArmyLlm.NATS.Consumer, []}
    ]
    |> maybe_exclude_consumer()

    opts = [strategy: :one_for_one, name: BotArmyLlm.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Setup telemetry handlers after supervisor starts (only in non-test)
    if @env != :test do
      BotArmyLlm.Telemetry.setup()
    end

    {:ok, pid}
  end

  # Exclude Consumer in tests to avoid connecting to real NATS
  defp maybe_exclude_consumer(children) do
    if @env == :test do
      Enum.reject(children, fn
        {BotArmyLlm.NATS.Consumer, []} -> true
        _ -> false
      end)
    else
      children
    end
  end
end
