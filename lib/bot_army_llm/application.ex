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
  @version Mix.Project.config()[:version]

  @impl true
  def start(_type, _args) do
    children =
      [
        # Database connection (optional in test when :start_repo is false — see config/test.exs)
        BotArmyLlm.Repo,

        # Circuit breaker registry for per-provider failure tracking
        {Registry, keys: :unique, name: BotArmyLlm.CircuitBreakerRegistry},

        # Circuit breakers for each LLM provider
        {BotArmyLlm.CircuitBreaker, :ollama},
        {BotArmyLlm.CircuitBreaker, :blackbox},
        {BotArmyLlm.CircuitBreaker, :openrouter},
        {BotArmyLlm.CircuitBreaker, :anthropic},

        # Note: BotArmyLibraryRuntime.NATS.Connection is started by BotArmyLibraryRuntime.Application supervisor.
        # Do not start it here - it's already managed by the runtime library.

        # Prompt storage (in-memory + Ecto persistence)
        {BotArmyLlm.PromptStore, []},

        # Conversation storage (in-memory + Ecto persistence)
        {BotArmyLlm.ConversationStore, []},

        # Vector store for RAG (pgvector embeddings)
        {BotArmyLlm.VectorStore, []},

        # Metrics collection (in-memory counters and percentiles)
        {BotArmyLlm.Metrics, []},

        # Shared-library outcome tracker — records LLM inference quality
        {BotArmyLibraryLearning.OutcomeTracker, [repo: BotArmyLlm.Repo, name: :llm_outcome_tracker]},

        # Embedding worker pool — bounded concurrency for embed requests
        {BotArmyLlm.EmbeddingWorkerPool, []},

        # Pulse publisher (reports inference health to Synapse every 5 min)
        {BotArmyLlm.PulsePublisher, []},

        # Ollama health checker (probes nodes every 60s, drives routing decisions)
        {BotArmyLlm.OllamaHealthChecker, []},

        # Local queue manager (tracks pending Ollama requests for visibility)
        {BotArmyLlm.LocalQueueManager, []},

        # Veto listener — vetoes GTD remind during active LLM conversations
        {BotArmyLibraryRuntime.Intent.VetoListener,
         rules: [
           [bot: "gtd", action: "remind", custom: &BotArmyLlm.VetoRules.veto_remind_during_chat/1]
         ],
         bot_name: "llm"},
        # Intent evaluator — proactive summarization when context warrants it
        {BotArmyLlm.IntentEvaluator, []},
        # NATS message consumer (depends on BotArmyLibraryRuntime.NATS.Connection being available)
        # Not started in tests to avoid connecting to real NATS
        {BotArmyLlm.NATS.Consumer, []}
      ]
      |> maybe_exclude_repo()
      |> maybe_exclude_consumer()
      |> maybe_exclude_pulse_publisher()
      |> maybe_http_proxy_children()
      |> maybe_add_health_responder()

    opts = [strategy: :one_for_one, name: BotArmyLlm.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Setup telemetry handlers after supervisor starts (only in non-test)
    if @env != :test do
      BotArmyLlm.Telemetry.setup()
    end

    {:ok, pid}
  end

  # Skip Repo in test unless BOT_ARMY_LLM_TEST_REPO=1 (avoids Postgrex errors when DB is missing)
  defp maybe_add_health_responder(children) do
    if @env == :test do
      children
    else
      children ++
        [
          {BotArmyLibraryRuntime.Health.Responder,
           [bot_name: :llm, repo: BotArmyLlm.Repo, version: @version]}
        ]
    end
  end

  defp maybe_exclude_repo(children) do
    if Application.get_env(:bot_army_llm, :start_repo, true) do
      children
    else
      Enum.reject(children, &(&1 == BotArmyLlm.Repo))
    end
  end

  # Exclude Consumer + VetoListener + IntentEvaluator in tests to avoid connecting to real NATS
  defp maybe_exclude_consumer(children) do
    if @env == :test do
      Enum.reject(children, fn
        {BotArmyLlm.NATS.Consumer, []} -> true
        {BotArmyLibraryRuntime.Intent.VetoListener, _} -> true
        {BotArmyLlm.IntentEvaluator, []} -> true
        _ -> false
      end)
    else
      children
    end
  end

  # Exclude PulsePublisher in tests to avoid connecting to real NATS
  defp maybe_exclude_pulse_publisher(children) do
    if @env == :test do
      Enum.reject(children, fn
        {BotArmyLlm.PulsePublisher, []} -> true
        _ -> false
      end)
    else
      children
    end
  end

  defp maybe_http_proxy_children(children) do
    cfg = Application.get_env(:bot_army_llm, :http_proxy, [])

    if Keyword.get(cfg, :enabled, false) do
      port = Keyword.fetch!(cfg, :port)
      ip = Keyword.get(cfg, :ip, {0, 0, 0, 0})

      finch =
        {Finch,
         name: BotArmyLlm.Finch,
         pools: %{
           "https://api.anthropic.com" => [size: 30, count: 1],
           default: [size: 50, count: 1]
         }}

      bandit =
        {Bandit, plug: BotArmyLlm.Http.Router, scheme: :http, port: port, ip: ip}

      children ++ [finch, bandit]
    else
      children
    end
  end
end
