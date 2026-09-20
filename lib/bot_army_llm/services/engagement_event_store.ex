defmodule BotArmyLlm.Services.EngagementEventStore do
  @moduledoc """
  Persistence layer for engagement events.

  Handles storing narrative shown/completed/skipped/abandoned events
  and provides query interfaces for the learning analyzer.
  """

  require Logger
  import Ecto.Query
  alias BotArmyLlm.Repo
  alias BotArmyLlm.Schemas.EngagementEvent

  @doc """
  Store an engagement event in the database.
  """
  @spec store_event(map()) :: {:ok, EngagementEvent.t()} | {:error, Ecto.Changeset.t()}
  def store_event(event_map) do
    changeset = EngagementEvent.changeset(event_map)

    case Repo.insert(changeset) do
      {:ok, event} ->
        Logger.debug("Stored engagement event for task #{event.task_id}")
        {:ok, event}

      {:error, changeset} ->
        Logger.error("Failed to store engagement event: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Fetch all engagement events for a user.
  """
  @spec events_for_user(String.t()) :: [EngagementEvent.t()]
  def events_for_user(user_id) do
    Repo.all(
      from(e in EngagementEvent,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at]
      )
    )
  end

  @doc """
  Fetch engagement events for a user and voice combination.
  """
  @spec events_for_user_voice(String.t(), String.t()) :: [EngagementEvent.t()]
  def events_for_user_voice(user_id, voice_key) do
    Repo.all(
      from(e in EngagementEvent,
        where: e.user_id == ^user_id and e.voice_key == ^voice_key,
        order_by: [desc: e.inserted_at]
      )
    )
  end

  @doc """
  Fetch events since a given timestamp.
  """
  @spec events_since(DateTime.t()) :: [EngagementEvent.t()]
  def events_since(since_dt) do
    Repo.all(
      from(e in EngagementEvent,
        where: e.inserted_at >= ^since_dt,
        order_by: [desc: e.inserted_at]
      )
    )
  end

  @doc """
  Fetch recent events for a user (limit).
  """
  @spec recent_events_for_user(String.t(), integer()) :: [EngagementEvent.t()]
  def recent_events_for_user(user_id, limit \\ 100) do
    Repo.all(
      from(e in EngagementEvent,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc """
  Convert stored EngagementEvent to map format expected by LearningAnalyzer.
  """
  @spec to_learning_format(EngagementEvent.t()) :: map()
  def to_learning_format(event) do
    %{
      "task_id" => event.task_id,
      "user_id" => event.user_id,
      "voice_key" => event.voice_key,
      "emotional_frame" => event.emotional_frame,
      "quest_type" => event.quest_type,
      "event_type" => event.event_type,
      "data" => event.data || %{},
      "timestamp" => event.inserted_at
    }
  end

  @doc """
  Fetch events for learning analysis.

  Returns events in format suitable for LearningAnalyzer.
  """
  @spec events_for_analysis(String.t(), integer()) :: [map()]
  def events_for_analysis(user_id, limit \\ 100) do
    recent_events_for_user(user_id, limit)
    |> Enum.map(&to_learning_format/1)
  end

  @doc """
  Count events by voice for a user.
  """
  @spec count_by_voice(String.t()) :: map()
  def count_by_voice(user_id) do
    Repo.all(
      from(e in EngagementEvent,
        where: e.user_id == ^user_id,
        group_by: e.voice_key,
        select: {e.voice_key, count(e.id)}
      )
    )
    |> Enum.into(%{})
  end

  @doc """
  Delete old events (older than N days) for cleanup.
  """
  @spec prune_old_events(integer()) :: {integer(), nil}
  def prune_old_events(days_old \\ 90) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old * 86400, :second)

    Repo.delete_all(
      from(e in EngagementEvent,
        where: e.inserted_at < ^cutoff_date
      )
    )
  end
end
