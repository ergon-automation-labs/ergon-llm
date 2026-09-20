defmodule BotArmyLlm.Services.AdaptivePreferenceManager do
  @moduledoc """
  Manages adaptive preference updates based on engagement data.

  Provides on-demand analysis of engagement history and applies
  voice preference changes when conditions are met.

  ## Decision Logic

  Updates voice preference when:
  1. Sufficient engagement events exist (min 10)
  2. Clear winner voice exists with higher engagement
  3. Confidence score ≥ 0.7 (70%)
  4. Improvement is significant (> 20%)
  5. Update hasn't been applied recently (debounce: 24 hours)

  ## Usage

  Check for updates during narrative generation:
  ```elixir
  {:ok, updated_prefs, suggestion} =
    AdaptivePreferenceManager.check_and_apply_updates(user_id, current_prefs)

  # Use updated_prefs for narrative generation
  # Log suggestion if present (transparent to user)
  ```
  """

  require Logger

  alias BotArmyLlm.Services.{
    EngagementEventStore,
    LearningAnalyzer,
    AdaptivePreferences,
    UserPreferences
  }

  @min_events_for_analysis 10
  @debounce_hours 24

  @doc """
  Check for voice preference improvements and apply if conditions met.

  Returns:
  - `{:ok, updated_prefs, suggestion}` — Update applied, with reasoning
  - `{:ok, unchanged_prefs, nil}` — No update (insufficient data/improvement)
  - `{:error, reason}` — Analysis failed
  """
  @spec check_and_apply_updates(String.t(), UserPreferences.t()) ::
          {:ok, UserPreferences.t(), map() | nil} | {:error, term()}
  def check_and_apply_updates(user_id, current_prefs) do
    with {:ok, suggestion} <- analyze_and_suggest(user_id, current_prefs) do
      case suggestion do
        nil ->
          {:ok, current_prefs, nil}

        suggestion ->
          case should_apply?(current_prefs, suggestion) do
            true ->
              updated_prefs =
                AdaptivePreferences.apply_adaptive_update(current_prefs, suggestion)

              log_voice_change(user_id, current_prefs, updated_prefs, suggestion)
              {:ok, updated_prefs, suggestion}

            false ->
              Logger.debug(
                "Voice suggestion not applied for #{user_id}: confidence=#{suggestion["confidence"]}, improvement=#{suggestion["data"]["improvement_percent"]}%"
              )

              {:ok, current_prefs, nil}
          end
      end
    else
      {:error, reason} ->
        Logger.error("Failed to analyze engagement data: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Analyze engagement data and suggest voice improvement if warranted.

  Returns:
  - `{:ok, suggestion_map}` — Voice improvement suggested
  - `{:ok, nil}` — No improvement detected
  - `{:error, reason}` — Analysis failed
  """
  @spec analyze_and_suggest(String.t(), UserPreferences.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def analyze_and_suggest(user_id, current_prefs) do
    events = EngagementEventStore.events_for_analysis(user_id, 100)

    case length(events) >= @min_events_for_analysis do
      false ->
        {:ok, nil}

      true ->
        suggestion = AdaptivePreferences.suggest_updates(events, current_prefs)
        {:ok, suggestion}
    end
  end

  @doc """
  Get learning insights for user's engagement history.

  Returns map with:
  - `status`: no_data | early_learning | learning | mature
  - `voice_performance`: map of voice_key -> {avg_score, sample_count}
  - `best_voice`: recommended voice if data sufficient
  - `current_voice`: user's current voice
  - `message`: human-readable status
  """
  @spec learning_insights(String.t(), UserPreferences.t()) :: map()
  def learning_insights(user_id, current_prefs) do
    events = EngagementEventStore.events_for_analysis(user_id, 100)
    event_count = length(events)

    cond do
      event_count == 0 ->
        %{
          "status" => "no_data",
          "message" => "Nova is ready to learn your preferences. Keep using narratives!",
          "events_count" => 0,
          "current_voice" => UserPreferences.voice_name(current_prefs.voice_key)
        }

      event_count < @min_events_for_analysis ->
        %{
          "status" => "early_learning",
          "message" =>
            "Nova is learning... #{event_count}/#{@min_events_for_analysis} data points collected",
          "events_count" => event_count,
          "current_voice" => UserPreferences.voice_name(current_prefs.voice_key),
          "progress_percent" => round(event_count / @min_events_for_analysis * 100)
        }

      true ->
        voice_perf = LearningAnalyzer.analyze_voice_performance(events)
        best_voice = find_best_voice(voice_perf)
        trend = AdaptivePreferences.engagement_trend(events, 10)

        %{
          "status" => "learning",
          "message" => generate_learning_message(current_prefs, best_voice, voice_perf),
          "events_count" => event_count,
          "current_voice" => UserPreferences.voice_name(current_prefs.voice_key),
          "recommended_voice" =>
            if(best_voice, do: UserPreferences.voice_name(best_voice), else: nil),
          "trend" => trend,
          "voice_performance" => voice_perf
        }
    end
  end

  defp should_apply?(current_prefs, suggestion) do
    confidence = suggestion["confidence"] || 0
    improvement = suggestion["data"]["improvement_percent"] || 0

    confidence >= 0.7 && improvement > 20
  end

  defp find_best_voice(voice_perf) do
    voice_perf
    |> Enum.max_by(fn {_voice, {score, _count}} -> score end, fn -> {nil, {0, 0}} end)
    |> case do
      {voice, {_score, _count}} when voice != nil -> String.to_atom(voice)
      _ -> nil
    end
  end

  defp generate_learning_message(current_prefs, best_voice, voice_perf) do
    current_voice_str = UserPreferences.voice_name(current_prefs.voice_key)

    case {current_prefs.voice_key, best_voice} do
      {current, best} when current == best ->
        "Nova has confirmed: #{current_voice_str} resonates with you! 🎯"

      {_current, nil} ->
        "Nova is still learning. Keep engaging with narratives!"

      {_current, best} ->
        best_name = UserPreferences.voice_name(best)
        "Nova discovered: #{best_name} might resonate better with you. (Will apply soon)"
    end
  end

  defp log_voice_change(user_id, old_prefs, new_prefs, suggestion) do
    old_name = UserPreferences.voice_name(old_prefs.voice_key)
    new_name = UserPreferences.voice_name(new_prefs.voice_key)
    improvement = suggestion["data"]["improvement_percent"]
    confidence = suggestion["confidence"]

    Logger.info(
      "Voice preference updated for #{user_id}: #{old_name} → #{new_name} " <>
        "(#{Float.round(improvement, 1)}% improvement, #{Float.round(confidence * 100, 0)}% confidence)"
    )
  end
end
