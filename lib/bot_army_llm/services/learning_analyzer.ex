defmodule BotArmyLlm.Services.LearningAnalyzer do
  @moduledoc """
  Analyze engagement patterns to learn user preferences.

  Processes engagement events to discover:
  - Which voices resonate most
  - Which emotional frames drive completion
  - Which quest types have highest engagement
  - Speed patterns and time-based preferences
  """

  @doc """
  Analyze voice performance from engagement events.

  Returns map of voice_key -> {avg_score, sample_count}
  """
  @spec analyze_voice_performance([map()]) :: map()
  def analyze_voice_performance(events) do
    events
    |> Enum.group_by(& &1["voice_key"])
    |> Enum.map(fn {voice_key, voice_events} ->
      scores = Enum.map(voice_events, &engagement_score/1)
      avg_score = Enum.sum(scores) / length(scores)
      {voice_key, {avg_score, length(voice_events)}}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Analyze emotional frame performance.

  Returns map of frame -> {avg_score, sample_count}
  """
  @spec analyze_frame_performance([map()]) :: map()
  def analyze_frame_performance(events) do
    events
    |> Enum.group_by(& &1["emotional_frame"])
    |> Enum.map(fn {frame, frame_events} ->
      scores = Enum.map(frame_events, &engagement_score/1)
      avg_score = Enum.sum(scores) / length(scores)
      {frame, {avg_score, length(frame_events)}}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Analyze quest type performance.

  Returns map of quest_type -> {avg_score, sample_count}
  """
  @spec analyze_quest_type_performance([map()]) :: map()
  def analyze_quest_type_performance(events) do
    events
    |> Enum.group_by(& &1["quest_type"])
    |> Enum.map(fn {quest_type, type_events} ->
      scores = Enum.map(type_events, &engagement_score/1)
      avg_score = Enum.sum(scores) / length(scores)
      {quest_type, {avg_score, length(type_events)}}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Calculate completion rate for a voice.

  Ratio of task_completed events to narrative_shown events.
  """
  @spec completion_rate_for_voice([map()], String.t()) :: float()
  def completion_rate_for_voice(events, voice_key) do
    voice_events = Enum.filter(events, &(&1["voice_key"] == voice_key))
    completions = Enum.count(voice_events, &(&1["event_type"] == "task_completed"))
    shown = Enum.count(voice_events, &(&1["event_type"] == "narrative_shown"))

    case shown do
      0 -> 0.0
      _ -> completions / shown
    end
  end

  @doc """
  Get recommended voice based on engagement data.

  Returns voice with highest average engagement score (with min sample threshold).
  """
  @spec recommend_voice([map()], integer()) :: atom() | nil
  def recommend_voice(events, min_samples \\ 3) do
    performance = analyze_voice_performance(events)

    performance
    |> Enum.filter(fn {_voice, {_score, count}} -> count >= min_samples end)
    |> Enum.max_by(fn {_voice, {score, _count}} -> score end, fn -> nil end)
    |> case do
      {voice, _stats} -> String.to_atom(voice)
      nil -> nil
    end
  end

  @doc """
  Get trending emotional frame.

  Returns frame with highest engagement across all events.
  """
  @spec trending_frame([map()], integer()) :: String.t() | nil
  def trending_frame(events, _recent_count \\ 10) do
    events
    |> analyze_frame_performance()
    |> Enum.max_by(fn {_frame, {score, _count}} -> score end, fn -> nil end)
    |> case do
      {frame, _stats} -> frame
      nil -> nil
    end
  end

  @doc """
  Generate learning summary from events.

  Returns insights about what's working.
  """
  @spec learning_summary([map()]) :: map()
  def learning_summary(events) when is_list(events) do
    case length(events) do
      0 ->
        %{
          "status" => "insufficient_data",
          "message" => "Need more engagement data to learn"
        }

      count when count < 5 ->
        %{
          "status" => "learning",
          "message" => "Early learning phase. " <> to_string(count) <> " events recorded.",
          "events_recorded" => count
        }

      _ ->
        voices = analyze_voice_performance(events)
        frames = analyze_frame_performance(events)
        best_voice = recommend_voice(events)
        trending = trending_frame(events)

        %{
          "status" => "learning",
          "events_recorded" => length(events),
          "best_voice" => best_voice,
          "voice_performance" => voices,
          "trending_frame" => trending,
          "frame_performance" => frames,
          "insight" => generate_insight(voices, frames)
        }
    end
  end

  # Private helpers

  defp engagement_score(event) do
    base_score =
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

    base_score + speed_bonus
  end

  defp generate_insight(voices, frames) do
    top_voice =
      voices
      |> Enum.max_by(fn {_voice, {score, _count}} -> score end, fn -> {nil, {0, 0}} end)
      |> case do
        {voice, {score, _count}} when score > 0 ->
          "Voice '#{voice}' is resonating well (score: #{Float.round(score, 2)})"

        _ ->
          "No clear voice preference yet"
      end

    top_frame =
      frames
      |> Enum.max_by(fn {_frame, {score, _count}} -> score end, fn -> {nil, {0, 0}} end)
      |> case do
        {frame, {score, _count}} when score > 0 ->
          "Frame '#{frame}' drives engagement (score: #{Float.round(score, 2)})"

        _ ->
          "No clear frame preference yet"
      end

    "#{top_voice}. #{top_frame}."
  end
end
