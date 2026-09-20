defmodule BotArmyLlm.Services.GtdBridgeClient do
  @moduledoc """
  Client for fetching task and project data from GTD bridge.

  Handles NATS requests to bridge.task.get and bridge.project.get
  to retrieve context for narrative generation.
  """

  require Logger
  alias BotArmyLibraryRuntime.NATS.Publisher

  @timeout_ms 3000

  @doc "Fetch task details by ID"
  def get_task(task_id, user_id \\ "abby") do
    request_body = %{
      "task_id" => task_id,
      "user_id" => user_id
    }

    case Publisher.request("bridge.task.get", request_body, timeout: @timeout_ms) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch task #{task_id}: #{inspect(reason)}")
        {:error, {:nats_error, reason}}
    end
  end

  @doc "Fetch project details by ID"
  def get_project(project_id, user_id \\ "abby") do
    request_body = %{
      "project_id" => project_id,
      "user_id" => user_id
    }

    case Publisher.request("bridge.project.get", request_body, timeout: @timeout_ms) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch project #{project_id}: #{inspect(reason)}")
        {:error, {:nats_error, reason}}
    end
  end

  @doc "Fetch task completion history for energy calculation"
  def get_completion_stats(user_id \\ "abby") do
    request_body = %{
      "user_id" => user_id,
      "days" => 7
    }

    case Publisher.request("bridge.task.completion_stats", request_body, timeout: @timeout_ms) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:error, _reason} ->
        # Fallback: return empty stats if bridge doesn't have this endpoint yet
        {:ok, %{"completions_today" => 0, "completions_this_week" => 0}}
    end
  end

  @doc "Fetch user's streak data"
  def get_streak_data(user_id \\ "abby") do
    request_body = %{
      "user_id" => user_id
    }

    case Publisher.request("bridge.task.streak", request_body, timeout: @timeout_ms) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:error, _reason} ->
        # Fallback: return default streak if bridge doesn't have this endpoint
        {:ok, %{"consecutive_days" => 0, "days_since_broken" => 0}}
    end
  end

  @doc """
  Build task context for narrative generation.

  Combines task, project, and user context into the format expected by
  the Nova prompt template.
  """
  def build_task_context(task, project, user_id \\ "abby") do
    now = DateTime.utc_now()
    hour = now.hour
    time_of_day = BotArmyLlm.Prompts.NovaTemplate.classify_time_of_day(hour)
    base_energy = BotArmyLlm.Prompts.NovaTemplate.base_energy_for_time(time_of_day)

    # Fetch streak and completion stats
    {:ok, streak_data} = get_streak_data(user_id)
    {:ok, completion_stats} = get_completion_stats(user_id)

    streak_days = Map.get(streak_data, "consecutive_days", 0)
    days_since_broken = Map.get(streak_data, "days_since_broken", 0)
    completions_today = Map.get(completion_stats, "completions_today", 0)

    # Calculate energy level
    energy_level =
      BotArmyLlm.Prompts.NovaTemplate.calculate_energy_level(
        base_energy,
        streak_days,
        days_since_broken,
        completions_today
      )

    %{
      "task_id" => Map.get(task, "id") || Map.get(task, "task_id"),
      "task_title" => Map.get(task, "title"),
      "task_description" => Map.get(task, "description", ""),
      "task_status" => Map.get(task, "status"),
      "project_id" => Map.get(project, "id") || Map.get(project, "project_id"),
      "project_name" => Map.get(project, "name"),
      "project_goal" => Map.get(project, "goal", Map.get(project, "description", "")),
      "user_id" => user_id,
      "time_of_day" => time_of_day,
      "hour" => hour,
      "energy_level" => energy_level,
      "streak" => %{
        "consecutive_days" => streak_days,
        "days_since_broken" => days_since_broken
      }
    }
  end

  @doc "Calculate input hash for cache validation"
  def calculate_input_hash(task_context) do
    hash_input =
      "#{task_context["task_title"]}#{task_context["project_goal"]}#{task_context["energy_level"]}#{task_context["time_of_day"]}#{task_context["streak"]["consecutive_days"]}#{task_context["streak"]["days_since_broken"]}"

    :crypto.hash(:sha256, hash_input)
    |> Base.encode16(case: :lower)
  end
end
