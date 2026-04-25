defmodule BotArmyLLM.PulsePublisher do
  @moduledoc """
  Publishes periodic health pulses from LLM bot to Synapse.

  LLM reports on inference operations:
  - Inferences processed and their latency
  - Error patterns (API failures, timeouts, token limits)
  - Model provider distribution (which LLM was used)
  - Queue depth and processing rate

  This helps Synapse understand:
  - Whether LLM is a bottleneck
  - Which models are performing well
  - Error patterns that might affect other bots
  - System capacity and load

  Pulse format:
    {
      "bot": "llm",
      "timestamp": "2026-04-25T10:25:00Z",
      "observations": {
        "inferences_processed": N,
        "avg_latency_ms": N,
        "error_count": N,
        "models_used": ["gpt-4", "claude", ...],
        "health_signal": "nominal|degraded|critical"
      }
    }
  """

  use GenServer
  require Logger

  # 5 minutes
  @publish_interval_ms 5 * 60 * 1000
  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting LLM bot pulse publisher")

    state = %{
      inferences_count: 0,
      total_latency_ms: 0,
      error_count: 0,
      models_used: MapSet.new()
    }

    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse(state) end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)

    # Reset counters for next period
    new_state = %{
      state
      | inferences_count: 0,
        total_latency_ms: 0,
        error_count: 0,
        models_used: MapSet.new()
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:record_inference, latency_ms, model}, _from, state) do
    new_state = %{
      state
      | inferences_count: state.inferences_count + 1,
        total_latency_ms: state.total_latency_ms + latency_ms,
        models_used: MapSet.put(state.models_used, model)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:record_error, _reason}, _from, state) do
    new_state = %{state | error_count: state.error_count + 1}
    {:reply, :ok, new_state}
  end

  # API for other modules to record inference metrics
  def record_inference(latency_ms, model) when is_integer(latency_ms) and is_binary(model) do
    try do
      GenServer.call(@server, {:record_inference, latency_ms, model})
    catch
      :exit, _ -> :ok
    end
  end

  def record_error(reason) do
    try do
      GenServer.call(@server, {:record_error, reason})
    catch
      :exit, _ -> :ok
    end
  end

  # Private

  defp publish_pulse(state) do
    pulse = build_pulse(state)
    publish_to_nats(pulse)
  end

  defp build_pulse(state) do
    avg_latency =
      if state.inferences_count > 0,
        do: div(state.total_latency_ms, state.inferences_count),
        else: 0

    health_signal =
      cond do
        state.error_count > 10 -> "critical"
        state.error_count > 5 -> "degraded"
        true -> "nominal"
      end

    %{
      "bot" => "llm",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "observations" => %{
        "inferences_processed" => state.inferences_count,
        "avg_latency_ms" => avg_latency,
        "error_count" => state.error_count,
        "models_used" => MapSet.to_list(state.models_used),
        "health_signal" => health_signal
      }
    }
  end

  defp publish_to_nats(pulse) do
    try do
      case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          json = Jason.encode!(pulse)

          case Gnat.pub(conn, "bot.llm.pulse", json) do
            :ok ->
              Logger.debug("[PulsePublisher] Published LLM pulse")

            {:error, reason} ->
              Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[PulsePublisher] NATS unavailable, skipping pulse: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning("[PulsePublisher] Error publishing pulse: #{inspect(e)}")
    end
  end
end
