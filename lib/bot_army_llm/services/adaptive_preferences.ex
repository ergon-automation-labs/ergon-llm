defmodule BotArmyLlm.Services.AdaptivePreferences do
  @moduledoc """
  Adaptive preference learning from engagement patterns.

  Reads engagement history and slowly adjusts Nova's voice/parameters
  to match what drives highest user engagement.

  Updates are conservative to avoid whiplash and maintain continuity.
  """

  alias BotArmyLlm.Services.LearningAnalyzer
  alias BotArmyLlm.Services.UserPreferences

  @doc """
  Generate adaptive preference updates from engagement data.

  Analyzes engagement history and returns suggested preference changes.
  Updates are conservative (max 1-2 point shifts per dimension).

  Returns:
    %{
      "new_voice_key" => :cheerleader,
      "confidence" => 0.75,
      "reason" => "Cheerleader voice has 30% higher completion rate",
      "data" => %{
        "voice_performance" => {...},
        "best_voice" => :cheerleader,
        "best_voice_score" => 12.5,
        "current_voice" => :disappointed_narrator,
        "current_voice_score" => 9.8,
        "improvement_percent" => 27.6
      }
    }
  """
  @spec suggest_updates([map()], map()) :: map() | nil
  def suggest_updates(engagement_events, current_prefs) when is_list(engagement_events) do
    case length(engagement_events) do
      count when count < 10 ->
        nil

      _ ->
        voice_performance = LearningAnalyzer.analyze_voice_performance(engagement_events)
        best_voice = recommend_best_voice(voice_performance, current_prefs.voice_key)

        case best_voice do
          nil ->
            nil

          recommendation ->
            generate_update_suggestion(recommendation, voice_performance, current_prefs)
        end
    end
  end

  @doc """
  Apply adaptive learning to user preferences.

  Updates voice if suggested improvement is significant enough.
  Conservative approach: only update if confidence >= 0.7 and improvement > 20%.
  """
  @spec apply_adaptive_update(map(), map(), map()) :: map()
  def apply_adaptive_update(current_prefs, suggestion, _opts \\ %{}) when is_map(suggestion) do
    confidence = suggestion["confidence"] || 0.5
    improvement = suggestion["data"]["improvement_percent"] || 0

    should_update = confidence >= 0.7 and improvement > 20

    if should_update do
      UserPreferences.set_voice(current_prefs, suggestion["new_voice_key"])
    else
      current_prefs
    end
  end

  @doc """
  Generate learning status message for display.

  Shows the user that Nova is learning their preferences.
  """
  @spec learning_message(map(), integer()) :: String.t() | nil
  def learning_message(engagement_events, min_events \\ 10) do
    case length(engagement_events) do
      0 ->
        "Nova is ready to learn your preferences."

      count when count < min_events ->
        remaining = min_events - count
        "Nova is learning... #{remaining} more interactions needed."

      count ->
        "Nova has learned from #{count} interactions."
    end
  end

  @doc """
  Calculate overall engagement trend.

  Returns :improving, :stable, or :declining based on recent events.
  """
  @spec engagement_trend([map()], integer()) :: atom()
  def engagement_trend(events, window \\ 5) do
    case length(events) do
      count when count < window * 2 ->
        :stable

      _ ->
        recent = Enum.take(events, window)
        older = Enum.slice(events, window, window)

        recent_avg = avg_engagement_score(recent)
        older_avg = avg_engagement_score(older)

        case {recent_avg - older_avg, recent_avg} do
          {diff, _} when diff > 2 -> :improving
          {diff, _} when diff < -2 -> :declining
          _ -> :stable
        end
    end
  end

  @doc """
  Get learning insights for dashboard display.

  Returns summary of what Nova has learned.
  """
  @spec insights([map()]) :: map()
  def insights(events) do
    case length(events) do
      0 ->
        %{
          "status" => "no_data",
          "message" => "No learning data yet"
        }

      count when count < 5 ->
        %{
          "status" => "early_learning",
          "message" => "Early learning phase. #{count} events recorded.",
          "events_count" => count
        }

      _ ->
        voice_perf = LearningAnalyzer.analyze_voice_performance(events)
        best_voice = find_best_voice(voice_perf)
        trend = engagement_trend(events)

        %{
          "status" => "learning",
          "events_count" => length(events),
          "trend" => trend,
          "best_voice" => best_voice,
          "message" => generate_insight_message(best_voice, trend)
        }
    end
  end

  # Private helpers

  defp recommend_best_voice(voice_performance, current_voice) do
    voice_performance
    |> Enum.filter(fn {voice, {score, count}} ->
      count >= 3 and voice != to_string(current_voice)
    end)
    |> Enum.max_by(fn {_voice, {score, _count}} -> score end, fn -> nil end)
    |> case do
      {voice, {_score, _count}} -> String.to_atom(voice)
      nil -> nil
    end
  end

  defp find_best_voice(voice_performance) do
    voice_performance
    |> Enum.max_by(fn {_voice, {score, _count}} -> score end, fn -> {nil, {0, 0}} end)
    |> case do
      {voice, _stats} when voice != nil -> String.to_atom(voice)
      _ -> nil
    end
  end

  defp generate_update_suggestion(best_voice, voice_perf, current_prefs) do
    {best_score_raw, _best_count} = voice_perf[to_string(best_voice)] || {0.0, 0}

    {current_score_raw, _current_count} =
      voice_perf[to_string(current_prefs.voice_key)] || {0.0, 0}

    best_score = best_score_raw * 1.0
    current_score = current_score_raw * 1.0

    improvement_percent =
      if current_score > 0 do
        (best_score - current_score) / current_score * 100.0
      else
        100.0
      end

    confidence = min(1.0, improvement_percent / 100.0)

    %{
      "new_voice_key" => best_voice,
      "confidence" => Float.round(confidence, 2),
      "reason" =>
        "#{voice_to_name(best_voice)} has #{Float.round(improvement_percent, 1)}% higher engagement",
      "data" => %{
        "voice_performance" => voice_perf,
        "best_voice" => best_voice,
        "best_voice_score" => Float.round(best_score, 2),
        "current_voice" => current_prefs.voice_key,
        "current_voice_score" => Float.round(current_score, 2),
        "improvement_percent" => Float.round(improvement_percent, 1)
      }
    }
  end

  defp avg_engagement_score(events) do
    case length(events) do
      0 ->
        0.0

      count ->
        scores = Enum.map(events, &calculate_engagement_score/1)
        Enum.sum(scores) / count
    end
  end

  defp calculate_engagement_score(event) do
    base =
      case event["event_type"] do
        "task_completed" -> 10.0
        "narrative_shown" -> 1.0
        "narrative_skipped" -> -5.0
        "task_abandoned" -> -3.0
        _ -> 0.0
      end

    speed_bonus =
      case event["data"]["completion_speed"] do
        "immediate" -> 2.0
        "quick" -> 2.0
        "moderate" -> 1.0
        _ -> 0.0
      end

    base + speed_bonus
  end

  defp voice_to_name(voice_key) do
    case voice_key do
      :cheerleader -> "Cheerleader"
      :drill_sergeant -> "Drill Sergeant"
      :gentle_guide -> "Gentle Guide"
      :mythic_oracle -> "Mythic Oracle"
      :disappointed_narrator -> "Disappointed Narrator"
      _ -> to_string(voice_key)
    end
  end

  defp generate_insight_message(best_voice, trend) do
    voice_name = voice_to_name(best_voice)

    case trend do
      :improving -> "Engagement improving. #{voice_name} resonates well."
      :declining -> "Engagement declining. Consider a voice change."
      :stable -> "Nova is learning what works for you."
    end
  end
end
