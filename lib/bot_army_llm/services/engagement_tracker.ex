defmodule BotArmyLlm.Services.EngagementTracker do
  @moduledoc """
  Track user engagement with narratives.

  Records events that indicate how well a narrative/voice resonated:
  - narrative_shown: displayed to user
  - narrative_completed: user completed the task
  - time_to_completion: how fast they moved
  - emotional_frame_resonance: did they engage with the frame?
  """

  @type engagement_event :: %{
          task_id: String.t(),
          user_id: String.t(),
          voice_key: atom(),
          emotional_frame: String.t(),
          quest_type: atom(),
          event_type: atom(),
          timestamp: DateTime.t(),
          data: map()
        }

  @doc """
  Record narrative shown event.

  Initial display of narrative to user.
  """
  @spec narrative_shown(String.t(), String.t(), atom(), String.t(), atom()) :: engagement_event()
  def narrative_shown(task_id, user_id, voice_key, emotional_frame, quest_type) do
    %{
      task_id: task_id,
      user_id: user_id,
      voice_key: voice_key,
      emotional_frame: emotional_frame,
      quest_type: quest_type,
      event_type: :narrative_shown,
      timestamp: DateTime.utc_now(),
      data: %{}
    }
  end

  @doc """
  Record task completion event.

  User completed the task associated with narrative.
  """
  @spec task_completed(
          String.t(),
          String.t(),
          atom(),
          String.t(),
          atom(),
          integer()
        ) :: engagement_event()
  def task_completed(
        task_id,
        user_id,
        voice_key,
        emotional_frame,
        quest_type,
        seconds_to_completion
      ) do
    %{
      task_id: task_id,
      user_id: user_id,
      voice_key: voice_key,
      emotional_frame: emotional_frame,
      quest_type: quest_type,
      event_type: :task_completed,
      timestamp: DateTime.utc_now(),
      data: %{
        "seconds_to_completion" => seconds_to_completion,
        "completion_speed" => classify_speed(seconds_to_completion)
      }
    }
  end

  @doc """
  Record narrative skip event.

  User dismissed/skipped the narrative without reading.
  """
  @spec narrative_skipped(String.t(), String.t(), atom(), String.t(), atom()) ::
          engagement_event()
  def narrative_skipped(task_id, user_id, voice_key, emotional_frame, quest_type) do
    %{
      task_id: task_id,
      user_id: user_id,
      voice_key: voice_key,
      emotional_frame: emotional_frame,
      quest_type: quest_type,
      event_type: :narrative_skipped,
      timestamp: DateTime.utc_now(),
      data: %{}
    }
  end

  @doc """
  Record narrative abandoned event.

  User started task but didn't complete it.
  """
  @spec task_abandoned(
          String.t(),
          String.t(),
          atom(),
          String.t(),
          atom(),
          integer()
        ) :: engagement_event()
  def task_abandoned(task_id, user_id, voice_key, emotional_frame, quest_type, seconds_active) do
    %{
      task_id: task_id,
      user_id: user_id,
      voice_key: voice_key,
      emotional_frame: emotional_frame,
      quest_type: quest_type,
      event_type: :task_abandoned,
      timestamp: DateTime.utc_now(),
      data: %{"seconds_active" => seconds_active}
    }
  end

  @doc """
  Classify speed of task completion.

  Returns atom indicating how quickly user moved.
  """
  @spec classify_speed(integer()) :: atom()
  def classify_speed(seconds) do
    cond do
      seconds < 60 -> :immediate
      seconds < 300 -> :quick
      seconds < 900 -> :moderate
      seconds < 1800 -> :thoughtful
      true -> :slow
    end
  end

  @doc """
  Calculate engagement score for an event.

  Higher = better engagement.
  - task_completed: +10 base
  - narrative_shown: +1 base
  - narrative_skipped: -5
  - task_abandoned: -3 + penalty for speed (faster = worse signal)
  """
  @spec engagement_score(engagement_event()) :: float()
  def engagement_score(event) do
    base_score =
      case event.event_type do
        :task_completed -> 10.0
        :narrative_shown -> 1.0
        :narrative_skipped -> -5.0
        :task_abandoned -> -3.0
        _ -> 0.0
      end

    # Completion speed bonus: fast completions are good (immediate/quick = +2, moderate = +1)
    speed_bonus =
      case event.data["completion_speed"] do
        :immediate -> 2.0
        :quick -> 2.0
        :moderate -> 1.0
        _ -> 0.0
      end

    base_score + speed_bonus
  end

  @doc """
  Encode engagement event for storage.
  """
  @spec encode(engagement_event()) :: String.t()
  def encode(event) do
    Jason.encode!(event)
  end

  @doc """
  Decode engagement event from storage.
  """
  @spec decode(String.t()) :: {:ok, engagement_event()} | :error
  def decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        event = %{
          task_id: decoded["task_id"],
          user_id: decoded["user_id"],
          voice_key: String.to_atom(decoded["voice_key"]),
          emotional_frame: decoded["emotional_frame"],
          quest_type: String.to_atom(decoded["quest_type"]),
          event_type: String.to_atom(decoded["event_type"]),
          timestamp: decoded["timestamp"],
          data: decoded["data"] || %{}
        }

        {:ok, event}

      {:error, _} ->
        :error
    end
  end
end
