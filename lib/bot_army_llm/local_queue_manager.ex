defmodule BotArmyLlm.LocalQueueManager do
  @moduledoc """
  Tracks pending local (Ollama) request queue depth.

  When the safety classifier detects sensitive data or explicit local routing occurs,
  requests are queued to Ollama. This GenServer maintains a simple counter of pending
  requests to provide visibility into local processing backlog.

  The counter increments when a request is about to be sent to Ollama and decrements
  when the request completes (success or failure).

  ## Usage

      LocalQueueManager.increment()
      # ... do work ...
      LocalQueueManager.decrement()

      # Query current depth
      count = LocalQueueManager.pending_count()
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

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{pending: 0}}
  end

  @impl true
  def handle_cast(:increment, state) do
    new_state = %{state | pending: state.pending + 1}
    Logger.debug("Local AI queue incremented: #{new_state.pending} pending requests")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:decrement, state) do
    new_count = max(0, state.pending - 1)
    new_state = %{state | pending: new_count}
    Logger.debug("Local AI queue decremented: #{new_count} pending requests")
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_count, _from, state) do
    {:reply, state.pending, state}
  end
end
