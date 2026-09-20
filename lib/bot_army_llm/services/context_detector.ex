defmodule BotArmyLlm.Services.ContextDetector do
  @moduledoc """
  Detects contextual information from task metadata.

  Extracts location, time of day, presence of others, and emotional state
  to inform scene-setting and narrative framing.

  Used by SceneFramer to create immersive, contextually relevant narratives.
  """

  require Logger

  @doc """
  Detect context from task data.

  Returns map with detected context:
  - location: inferred from task tags or location field
  - time_period: morning/afternoon/evening/night
  - presence: alone/with_partner/group
  - energy_level: calculated from task data
  """
  @spec detect(map()) :: map()
  def detect(task) when is_map(task) do
    %{
      "location" => detect_location(task),
      "time_period" => detect_time_period(task),
      "presence" => detect_presence(task),
      "energy_level" => detect_energy(task),
      "intensity" => detect_intensity(task)
    }
  end

  @doc """
  Detect primary location from task metadata.

  Returns atom: :bathroom, :kitchen, :bedroom, :gym, :work, :couch, :unknown
  """
  @spec detect_location(map()) :: atom()
  def detect_location(task) do
    tags = task["tags"] || []
    description = (task["description"] || "") <> (task["title"] || "")

    cond do
      Enum.any?(tags, &String.contains?(&1, ["bathroom", "shower", "wash", "hygiene"])) ->
        :bathroom

      Enum.any?(tags, &String.contains?(&1, ["kitchen", "cook", "meal", "food", "eat"])) ->
        :kitchen

      Enum.any?(tags, &String.contains?(&1, ["bedroom", "bed", "sleep", "rest"])) ->
        :bedroom

      Enum.any?(tags, &String.contains?(&1, ["gym", "exercise", "workout", "run", "lift"])) ->
        :gym

      Enum.any?(tags, &String.contains?(&1, ["work", "office", "meeting", "code"])) ->
        :work

      Enum.any?(tags, &String.contains?(&1, ["couch", "relax", "chill", "watch"])) ->
        :couch

      String.contains?(description, ["bathroom", "shower", "wash"]) ->
        :bathroom

      String.contains?(description, ["kitchen", "cook", "meal"]) ->
        :kitchen

      String.contains?(description, ["gym", "exercise", "workout"]) ->
        :gym

      true ->
        :unknown
    end
  end

  @doc """
  Detect time period from task or current time.
  """
  @spec detect_time_period(map()) :: atom()
  def detect_time_period(task) do
    # Check task metadata first
    case task["time_period"] do
      period when period in ["morning", "afternoon", "evening", "night"] ->
        String.to_atom(period)

      _ ->
        # Fall back to current time
        hour = DateTime.utc_now().hour

        cond do
          hour >= 5 and hour < 12 -> :morning
          hour >= 12 and hour < 17 -> :afternoon
          hour >= 17 and hour < 21 -> :evening
          true -> :night
        end
    end
  end

  @doc """
  Detect presence of others from task metadata.
  """
  @spec detect_presence(map()) :: atom()
  def detect_presence(task) do
    collaborators = task["collaborators"] || []
    tags = task["tags"] || []
    description = (task["description"] || "") <> (task["title"] || "")

    cond do
      Enum.any?(tags, &String.contains?(&1, ["with louiza", "louiza", "partner"])) ->
        :with_partner

      String.contains?(description, ["with louiza"]) or String.contains?(description, ["louiza"]) ->
        :with_partner

      length(collaborators) > 1 ->
        :group

      length(collaborators) == 1 ->
        :with_partner

      Enum.any?(tags, &String.contains?(&1, ["group", "team"])) ->
        :group

      true ->
        :alone
    end
  end

  @doc """
  Detect energy level from task metadata.
  """
  @spec detect_energy(map()) :: atom()
  def detect_energy(task) do
    energy = task["energy_level"] || 5

    cond do
      energy >= 8 -> :high
      energy >= 5 -> :medium
      true -> :low
    end
  end

  @doc """
  Detect task intensity (how physically/mentally demanding).
  """
  @spec detect_intensity(map()) :: atom()
  def detect_intensity(task) do
    duration = task["estimated_duration"] || 30
    tags = task["tags"] || []
    is_physical = Enum.any?(tags, &String.contains?(&1, ["exercise", "workout", "gym", "move"]))

    cond do
      is_physical and duration > 30 -> :high
      duration > 60 -> :high
      duration > 30 -> :medium
      true -> :low
    end
  end

  @doc """
  Check if context is a self-care location.
  """
  @spec is_self_care_location?(atom()) :: boolean()
  def is_self_care_location?(location) do
    location in [:bathroom, :bedroom, :couch]
  end

  @doc """
  Check if context is a movement/activity location.
  """
  @spec is_activity_location?(atom()) :: boolean()
  def is_activity_location?(location) do
    location in [:gym, :kitchen]
  end
end
