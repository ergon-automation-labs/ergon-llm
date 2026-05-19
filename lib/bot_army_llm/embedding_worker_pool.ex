defmodule BotArmyLlm.EmbeddingWorkerPool do
  @moduledoc """
  Bounded worker pool for embedding requests.

  Replaces the bare `spawn/1` in the NATS consumer with a FIFO queue +
  configurable max concurrency. Prevents overwhelming the Ollama embed
  endpoint when large document ingestion jobs enqueue thousands of chunks.

  Telemetry:
  - Logs warning when queue depth exceeds 20.
  - Logs info on pool start with configured max_concurrency.
  """
  use GenServer
  alias BotArmyLlm.Handlers.EmbeddingHandler
  require Logger

  @default_max_concurrency 5
  @queue_depth_warn_threshold 20

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def enqueue(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:enqueue, message})
  end

  def done do
    GenServer.cast(__MODULE__, :done)
  end

  @impl true
  def init(_opts) do
    max_concurrency = max_concurrency_from_env()

    Logger.info("[EmbeddingWorkerPool] Starting with max_concurrency=#{max_concurrency}")

    {:ok, %{max_concurrency: max_concurrency, inflight: 0, queue: :queue.new()}}
  end

  @impl true
  def handle_cast({:enqueue, message}, state) do
    if state.inflight < state.max_concurrency do
      {:noreply, spawn_embed_task(message, state)}
    else
      queue = :queue.in(message, state.queue)
      depth = :queue.len(queue)

      if depth > @queue_depth_warn_threshold do
        Logger.warning("[EmbeddingWorkerPool] Queue depth=#{depth} exceeds warning threshold")
      end

      {:noreply, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_cast(:done, state) do
    state = %{state | inflight: max(state.inflight - 1, 0)}

    case :queue.out(state.queue) do
      {{:value, message}, queue} ->
        {:noreply, spawn_embed_task(message, %{state | queue: queue})}

      {:empty, _} ->
        {:noreply, state}
    end
  end

  defp spawn_embed_task(message, state) do
    Task.start(fn ->
      try do
        EmbeddingHandler.handle_embed(message)
      after
        done()
      end
    end)

    %{state | inflight: state.inflight + 1}
  end

  defp max_concurrency_from_env do
    case System.get_env("BOT_ARMY_LLM_EMBED_MAX_CONCURRENCY") do
      nil ->
        @default_max_concurrency

      raw ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> n
          _ -> @default_max_concurrency
        end
    end
  end
end
