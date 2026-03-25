defmodule BotArmyLlm.LocalQueueManager do
  @moduledoc """
  Tracks pending LLM request queue depth for visibility in TUI status display.

  This GenServer maintains a counter of in-flight LLM requests across all providers
  (Ollama, Blackbox, OpenRouter, Anthropic) to provide TUI with queue depth metrics.

  The counter increments when an LLM request is submitted and decrements when it
  completes (success or failure). Queue status is polled every 2 seconds by the TUI
  via llm.queue.status request/reply endpoint.

  ## Usage

      LocalQueueManager.increment()
      # ... do LLM work ...
      LocalQueueManager.decrement()

      # Query current depth and breakdown
      status = LocalQueueManager.queue_status()
      # Returns: %{pending_total: int, actively_processing: int, queued_waiting: int, last_activity_at: timestamp}
  """

  use GenServer
  require Logger

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment pending local request count. Called when request is added to Ollama queue."
  def increment() do
    GenServer.cast(__MODULE__, :increment)
  end

  @doc "Decrement pending local request count. Called when request completes."
  def decrement() do
    GenServer.cast(__MODULE__, :decrement)
  end

  @doc "Get current number of pending local requests."
  @spec pending_count() :: non_neg_integer()
  def pending_count() do
    GenServer.call(__MODULE__, :get_count)
  end

  @doc "Get queue status including active/queued breakdown and last activity time."
  def queue_status() do
    GenServer.call(__MODULE__, :get_status)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{pending: 0, last_activity_at: nil}}
  end

  @impl true
  def handle_cast(:increment, state) do
    new_state = %{state | pending: state.pending + 1, last_activity_at: DateTime.utc_now()}
    Logger.debug("Local AI queue incremented: #{new_state.pending} pending requests")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:decrement, state) do
    new_count = max(0, state.pending - 1)
    new_state = %{state | pending: new_count, last_activity_at: DateTime.utc_now()}
    Logger.debug("Local AI queue decremented: #{new_count} pending requests")
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_count, _from, state) do
    {:reply, state.pending, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    # Assume 1 request actively processing when queue > 0, rest are waiting
    active = min(1, state.pending)
    queued = max(0, state.pending - active)

    response = %{
      "pending_total" => state.pending,
      "actively_processing" => active,
      "queued_waiting" => queued,
      "last_activity_at" => state.last_activity_at |> format_timestamp()
    }

    {:reply, response, state}
  end

  defp format_timestamp(nil), do: nil
  defp format_timestamp(dt), do: DateTime.to_iso8601(dt)
end
