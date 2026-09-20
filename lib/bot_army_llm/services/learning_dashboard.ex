defmodule BotArmyLlm.Services.LearningDashboard do
  @moduledoc """
  Provides learning status and dashboard data for Nova users.

  Generates user-facing feedback about Nova's learning progress,
  voice improvements, and personalization insights.

  Consumed by dashboard UI components to display learning feedback.
  """

  require Logger

  alias BotArmyLlm.Services.{
    AdaptivePreferenceManager,
    UserPreferences,
    EngagementEventStore,
    LearningAnalyzer
  }

  @doc """
  Get comprehensive learning dashboard data for a user.

  Returns map with learning status, metrics, and recommendations.
  """
  @spec dashboard_data(String.t(), UserPreferences.t()) :: map()
  def dashboard_data(user_id, prefs) do
    insights = AdaptivePreferenceManager.learning_insights(user_id, prefs)
    events = EngagementEventStore.events_for_analysis(user_id, 100)

    voice_perf =
      if length(events) > 0, do: LearningAnalyzer.analyze_voice_performance(events), else: %{}

    %{
      "status" => insights["status"],
      "message" => insights["message"],
      "current_voice" => UserPreferences.voice_name(prefs.voice_key),
      "current_voice_key" => prefs.voice_key,
      "recommended_voice" => insights["recommended_voice"],
      "progress" => build_progress(insights),
      "metrics" => build_metrics(events, voice_perf),
      "recent_changes" => get_recent_voice_changes(user_id),
      "call_to_action" => get_call_to_action(insights)
    }
  end

  @doc """
  Get simple learning status message for in-narrative display.

  Returns brief status string like "Nova is learning..." or "Nova knows you prefer...".
  """
  @spec status_message(String.t(), UserPreferences.t()) :: String.t()
  def status_message(user_id, prefs) do
    insights = AdaptivePreferenceManager.learning_insights(user_id, prefs)
    insights["message"]
  end

  @doc """
  Get voice improvement suggestion if available.

  Returns map with suggestion details or nil if not applicable.
  """
  @spec get_suggestion(String.t(), UserPreferences.t()) :: map() | nil
  def get_suggestion(user_id, prefs) do
    case AdaptivePreferenceManager.check_and_apply_updates(user_id, prefs) do
      {:ok, _updated_prefs, suggestion} when not is_nil(suggestion) ->
        %{
          "new_voice" => UserPreferences.voice_name(suggestion["new_voice_key"]),
          "improvement_percent" => suggestion["data"]["improvement_percent"],
          "confidence_percent" => round(suggestion["confidence"] * 100),
          "reason" => suggestion["reason"]
        }

      _ ->
        nil
    end
  end

  @doc """
  Get learning timeline showing voice preference changes over time.

  Returns list of voice changes with timestamps and reasons.
  """
  @spec voice_change_timeline(String.t(), integer()) :: list(map())
  def voice_change_timeline(user_id, limit \\ 10) do
    events = EngagementEventStore.events_for_analysis(user_id, 1000)

    # Track voice changes by grouping events and detecting shifts
    events
    |> Enum.group_by(& &1["voice_key"])
    |> Enum.map(fn {voice_key, voice_events} ->
      %{
        "voice" => UserPreferences.voice_name(String.to_atom(voice_key)),
        "voice_key" => voice_key,
        "event_count" => length(voice_events),
        "first_seen" => (voice_events |> Enum.min_by(fn e -> e["timestamp"] end))["timestamp"],
        "last_seen" => (voice_events |> Enum.max_by(fn e -> e["timestamp"] end))["timestamp"]
      }
    end)
    |> Enum.sort_by(& &1["last_seen"], {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Check if user has enough data for learning recommendations.
  """
  @spec is_learning(String.t()) :: boolean()
  def is_learning(user_id) do
    events = EngagementEventStore.recent_events_for_user(user_id, 100)
    length(events) >= 10
  end

  @doc """
  Get learning health check for system diagnostics.

  Returns status indicating if learning system is operating normally.
  """
  @spec health_check(String.t()) :: map()
  def health_check(user_id) do
    events = EngagementEventStore.recent_events_for_user(user_id, 100)
    event_count = length(events)

    %{
      "status" => if(event_count > 0, do: "operational", else: "warming_up"),
      "events_recorded" => event_count,
      "events_needed_for_learning" => 10,
      "ready_for_recommendations" => event_count >= 10,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Private helpers

  defp build_progress(insights) do
    case insights["status"] do
      "no_data" ->
        %{
          "stage" => "ready",
          "message" => "Start using narratives to help Nova learn",
          "percent" => 0
        }

      "early_learning" ->
        percent = insights["progress_percent"] || 0

        %{
          "stage" => "learning",
          "message" => "#{percent}% of the way to first insights",
          "percent" => percent
        }

      "learning" ->
        %{
          "stage" => "personalizing",
          "message" => "Nova is building your personalized experience",
          "percent" => 100
        }

      _ ->
        %{
          "stage" => "unknown",
          "message" => "Learning system status unknown",
          "percent" => 0
        }
    end
  end

  defp build_metrics(events, voice_perf) do
    event_count = length(events)
    completion_rate = if event_count > 0, do: count_completions(events) / event_count, else: 0

    %{
      "total_events" => event_count,
      "completion_rate_percent" => round(completion_rate * 100),
      "voice_performance" =>
        voice_perf
        |> Enum.map(fn {voice_key, {avg_score, count}} ->
          %{
            "voice" => UserPreferences.voice_name(String.to_atom(voice_key)),
            "voice_key" => voice_key,
            "engagement_score" => Float.round(avg_score, 2),
            "sample_count" => count
          }
        end)
        |> Enum.sort_by(& &1["engagement_score"], :desc)
    }
  end

  defp get_recent_voice_changes(user_id) do
    timeline = voice_change_timeline(user_id, 3)

    if length(timeline) > 1 do
      timeline
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        Map.put(entry, "sequence", idx + 1)
      end)
    else
      []
    end
  end

  defp get_call_to_action(insights) do
    case insights["status"] do
      "no_data" ->
        "Keep using Nova narratives and it will start learning your preferences!"

      "early_learning" ->
        progress = insights["progress_percent"] || 0

        if progress < 50 do
          "You're #{progress}% of the way to Nova learning your preferences. Keep going!"
        else
          "Almost there! #{100 - progress}% more interactions and Nova will have insights for you."
        end

      "learning" ->
        if insights["recommended_voice"] &&
             insights["recommended_voice"] != insights["current_voice"] do
          "Nova has discovered a voice you might prefer. It will use it next!"
        else
          "Nova is confident in your current voice preference. Enjoying it?"
        end

      _ ->
        "Nova is learning. Come back later for personalization insights!"
    end
  end

  defp count_completions(events) do
    Enum.count(events, &(&1["event_type"] == "task_completed"))
  end
end
