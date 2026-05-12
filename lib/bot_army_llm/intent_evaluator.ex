defmodule BotArmyLlm.IntentEvaluator do
  @moduledoc false

  use GenServer

  require Logger

  alias BotArmyRuntime.Intent.AccumulatedContext
  alias BotArmyRuntime.Intent.Publisher
  alias BotArmyRuntime.Intent.ThresholdModel

  @bot_name "llm"
  @evaluate_interval_ms 5 * 60 * 1000

  @default_thresholds %{
    unsummarized_events: %{min: 20, weight: 0.6},
    idle_minutes: %{min: 120, weight: 0.4},
    random_threshold: 0.5
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record_observations(map()) :: :ok
  def record_observations(pulse_data) do
    GenServer.cast(__MODULE__, {:record_observations, pulse_data})
  end

  @spec evaluate_now() :: {:ok, [any()]} | {:error, term()}
  def evaluate_now do
    GenServer.call(__MODULE__, :evaluate_now, 10_000)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :evaluate, @evaluate_interval_ms)
    {:ok, %{last_evaluation: nil}}
  end

  @impl true
  def handle_cast({:record_observations, pulse_data}, state) do
    observations = extract_observations(pulse_data)
    Enum.each(observations, &AccumulatedContext.record(@bot_name, &1))
    {:noreply, state}
  end

  @impl true
  def handle_call(:evaluate_now, _from, state) do
    results = do_evaluate()
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    results = do_evaluate()

    acted_count =
      Enum.count(results, fn
        {:acted, _, _, _, _} -> true
        _ -> false
      end)

    Logger.debug("[LLM.Intent] Evaluated #{length(results)} intents, #{acted_count} acted")
    Process.send_after(self(), :evaluate, @evaluate_interval_ms)
    {:noreply, %{state | last_evaluation: DateTime.utc_now()}}
  end

  defp do_evaluate do
    thresholds = get_thresholds()
    context = AccumulatedContext.snapshot(@bot_name)

    evaluate_intent("summarize", thresholds, context)
  end

  defp evaluate_intent(action, thresholds, context) do
    case ThresholdModel.evaluate(@bot_name, action, thresholds, context) do
      {:ok, :act, details} ->
        Logger.info("[LLM.Intent] Acting on #{action} (score=#{details.score})")

        case Publisher.publish_intent(@bot_name, action, %{
               threshold_result: details,
               context_snapshot: %{entry_count: context.entry_count}
             }) do
          {:proceed, intent_id, endorsements} ->
            Logger.info("[LLM.Intent] Proceeding with #{action} (intent_id=#{intent_id})")
            [{:acted, action, intent_id, details, endorsements}]

          {:vetoed, vetoing_bot, reason} ->
            Logger.info("[LLM.Intent] #{action} vetoed by #{vetoing_bot}: #{reason}")
            [{:vetoed, action, vetoing_bot, reason}]

          {:error, reason} ->
            Logger.warning("[LLM.Intent] Failed to publish #{action}: #{inspect(reason)}")
            []
        end

      {:ok, :defer, details} ->
        Logger.debug("[LLM.Intent] Deferring #{action} (score=#{details.score})")
        []

      {:ok, :abort, details} ->
        Logger.debug("[LLM.Intent] Aborting #{action} (score=#{details.score})")
        []

      {:error, :disabled} ->
        []

      {:error, reason} ->
        Logger.warning("[LLM.Intent] Error evaluating #{action}: #{inspect(reason)}")
        []
    end
  end

  def extract_observations(pulse_data) do
    events = get_in(pulse_data, ["observations", "unsummarized_events"]) || 0
    idle = get_in(pulse_data, ["observations", "idle_minutes"]) || 0

    observations = []

    observations =
      if events > 0 do
        [
          %{
            type: :unsummarized_events,
            value: events,
            observed_at: DateTime.utc_now(),
            metadata: %{source: "pulse"}
          }
          | observations
        ]
      else
        observations
      end

    observations =
      if idle > 0 do
        [
          %{
            type: :idle_minutes,
            value: idle,
            observed_at: DateTime.utc_now(),
            metadata: %{source: "pulse"}
          }
          | observations
        ]
      else
        observations
      end

    observations
  end

  defp get_thresholds do
    Application.get_env(:bot_army_llm, :intent_thresholds, @default_thresholds)
  end
end
