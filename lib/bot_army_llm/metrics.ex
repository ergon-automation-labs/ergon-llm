defmodule BotArmyLlm.Metrics do
  @moduledoc """
  In-memory metrics collection and telemetry event handling.

  Collects performance data about LLM operations:
  - Request counts by event type
  - Error counts by type
  - Provider call counts
  - Latency percentiles
  - RAG operations
  """

  use GenServer
  require Logger

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record an outgoing request"
  def record_request(event_type) when is_binary(event_type) do
    GenServer.cast(__MODULE__, {:record_request, event_type})
  end

  @doc "Record an error"
  def record_error(event_type, error_type) when is_binary(event_type) and is_binary(error_type) do
    GenServer.cast(__MODULE__, {:record_error, event_type, error_type})
  end

  @doc "Record a provider call with latency"
  def record_provider_call(provider, latency_ms)
      when is_binary(provider) and is_integer(latency_ms) do
    GenServer.cast(__MODULE__, {:record_provider_call, provider, latency_ms})
  end

  @doc "Record a provider fallback event"
  def record_provider_fallback do
    GenServer.cast(__MODULE__, :record_provider_fallback)
  end

  @doc "Record RAG index operation"
  def record_rag_index do
    GenServer.cast(__MODULE__, :record_rag_index)
  end

  @doc "Record RAG search operation"
  def record_rag_search do
    GenServer.cast(__MODULE__, :record_rag_search)
  end

  @doc "Record lane-level request count"
  def record_lane_request(lane) when is_binary(lane) do
    GenServer.cast(__MODULE__, {:record_lane_request, lane})
  end

  @doc "Record lane-level latency sample (ms)"
  def record_lane_latency(lane, latency_ms) when is_binary(lane) and is_integer(latency_ms) do
    GenServer.cast(__MODULE__, {:record_lane_latency, lane, latency_ms})
  end

  @doc "Get current metrics summary"
  def get_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @doc "Reset all metrics (for testing)"
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting Metrics collector")

    state = %{
      requests: %{},
      errors: %{},
      provider_calls: %{},
      provider_errors: %{},
      provider_fallbacks: 0,
      latencies: %{},
      lane_requests: %{},
      lane_latencies: %{},
      rag_indexed: 0,
      rag_searched: 0,
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_request, event_type}, state) do
    requests = Map.update(state.requests, event_type, 1, &(&1 + 1))
    {:noreply, %{state | requests: requests}}
  end

  def handle_cast({:record_error, event_type, error_type}, state) do
    errors = state.errors
    event_errors = Map.get(errors, event_type, %{})
    updated_event_errors = Map.update(event_errors, error_type, 1, &(&1 + 1))
    updated_errors = Map.put(errors, event_type, updated_event_errors)

    {:noreply, %{state | errors: updated_errors}}
  end

  def handle_cast({:record_provider_call, provider, latency_ms}, state) do
    provider_calls = Map.update(state.provider_calls, provider, 1, &(&1 + 1))

    latencies = state.latencies
    provider_latencies = Map.get(latencies, provider, [])

    # Keep last 1000 latencies per provider
    updated_latencies = Enum.take([latency_ms | provider_latencies], 1000)
    updated_latencies_map = Map.put(latencies, provider, updated_latencies)

    {:noreply,
     %{
       state
       | provider_calls: provider_calls,
         latencies: updated_latencies_map
     }}
  end

  def handle_cast(:record_provider_fallback, state) do
    {:noreply, %{state | provider_fallbacks: state.provider_fallbacks + 1}}
  end

  def handle_cast(:record_rag_index, state) do
    {:noreply, %{state | rag_indexed: state.rag_indexed + 1}}
  end

  def handle_cast(:record_rag_search, state) do
    {:noreply, %{state | rag_searched: state.rag_searched + 1}}
  end

  def handle_cast({:record_lane_request, lane}, state) do
    lane_requests = Map.update(state.lane_requests, lane, 1, &(&1 + 1))
    {:noreply, %{state | lane_requests: lane_requests}}
  end

  def handle_cast({:record_lane_latency, lane, latency_ms}, state) do
    lane_latencies = state.lane_latencies
    samples = Map.get(lane_latencies, lane, [])

    # Keep last 1000 latency samples per lane.
    updated_samples = Enum.take([latency_ms | samples], 1000)
    updated_lane_latencies = Map.put(lane_latencies, lane, updated_samples)

    {:noreply, %{state | lane_latencies: updated_lane_latencies}}
  end

  def handle_cast(:reset, _state) do
    new_state = %{
      requests: %{},
      errors: %{},
      provider_calls: %{},
      provider_errors: %{},
      provider_fallbacks: 0,
      latencies: %{},
      lane_requests: %{},
      lane_latencies: %{},
      rag_indexed: 0,
      rag_searched: 0,
      started_at: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = build_summary(state)
    {:reply, summary, state}
  end

  # Private functions

  defp build_summary(state) do
    uptime_seconds = DateTime.diff(DateTime.utc_now(), state.started_at)

    %{
      uptime_seconds: uptime_seconds,
      requests: state.requests,
      errors: state.errors,
      provider_calls: state.provider_calls,
      provider_errors: state.provider_errors,
      provider_fallbacks: state.provider_fallbacks,
      latency_percentiles: compute_percentiles(state.latencies),
      lane_requests: state.lane_requests,
      lane_latency_percentiles: compute_percentiles(state.lane_latencies),
      rag_indexed: state.rag_indexed,
      rag_searched: state.rag_searched
    }
  end

  defp compute_percentiles(latencies) do
    Enum.map(latencies, fn {provider, latency_list} ->
      sorted = Enum.sort(latency_list)
      count = length(sorted)

      {provider,
       %{
         p50: percentile(sorted, 0.50, count),
         p95: percentile(sorted, 0.95, count),
         p99: percentile(sorted, 0.99, count),
         min: Enum.min(sorted),
         max: Enum.max(sorted)
       }}
    end)
    |> Map.new()
  end

  defp percentile(sorted_list, percentile, count) when count > 0 do
    index = max(0, round(percentile * count) - 1)
    Enum.at(sorted_list, index, 0)
  end

  defp percentile(_, _, _), do: 0
end
