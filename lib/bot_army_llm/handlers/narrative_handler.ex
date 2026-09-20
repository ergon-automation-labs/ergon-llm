defmodule BotArmyLlm.Handlers.NarrativeHandler do
  @moduledoc """
  Generates narrative text for Nova tasks based on task context, time of day, and energy level.

  Handles `bridge.narrative.refresh` requests and returns evocative story text
  that frames mundane tasks as quest beats in an interactive visual novel.

  ## Cache Logic (Phase 2)

  1. Calculate input hash from task_title + project_goal + energy + time + streak
  2. Check cache: if valid hash and not expired, return cached narrative
  3. If cache miss or stale:
     - Fetch task from GTD bridge
     - Fetch project from GTD bridge
     - Calculate energy level from streak + time + completions
     - Request LLM generation (Phase 3+)
     - Store in cache
  """

  require Logger
  alias BotArmyLlm.Services.NarrativeCache
  alias BotArmyLlm.Services.GtdBridgeClient
  alias BotArmyLlm.Services.NarrativeLlm
  alias BotArmyLlm.Services.ImageLibrary
  alias BotArmyLlm.Services.QuestTypeClassifier
  alias BotArmyLlm.Services.QuestDifficulty
  alias BotArmyLlm.Services.ReflectionPrompts
  alias BotArmyLibraryRuntime.NATS.Publisher

  def handle_narrative_request(message, reply_to) do
    task_id = message["task_id"]
    force = message["force"] || false
    user_id = message["user_id"] || "abby"

    Logger.info("Narrative request for task #{task_id}, force=#{force}, user=#{user_id}")

    case generate_or_fetch_narrative(task_id, user_id, force) do
      {:ok, narrative, generated_by, quest_type, task} ->
        emotional_frame = narrative["emotional_frame"] || "neutral"
        image_urls = ImageLibrary.images_for_frame(emotional_frame)
        quest_metadata = QuestTypeClassifier.metadata(quest_type)
        difficulty = QuestDifficulty.calculate(task)
        max_hp = QuestDifficulty.difficulty_to_hp(difficulty)

        energy_level = Map.get(task, "energy_level", 5)

        reflection_prompts =
          if quest_type == :reflection do
            ReflectionPrompts.get_prompt_rotation(energy_level, emotional_frame, 5)
          else
            []
          end

        response = %{
          "narrative" => narrative,
          "quest_type" => quest_type,
          "images" => %{
            "emotional_frame" => emotional_frame,
            "urls" => image_urls,
            "current_index" => 0
          },
          "quest_metadata" => quest_metadata,
          "mechanics" => %{
            "difficulty" => difficulty,
            "max_hp" => max_hp,
            "reflection_prompts" => reflection_prompts
          },
          "metadata" => %{
            "generated_by" => generated_by,
            "model" => "claude-opus-5",
            "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "valid_until" => valid_until()
          }
        }

        publish_reply(reply_to, response)

      {:error, reason} ->
        Logger.error("Narrative generation failed: #{inspect(reason)}")

        error_response = %{
          "event" => "error",
          "error" => inspect(reason),
          "task_id" => task_id
        }

        publish_reply(reply_to, error_response)
    end
  end

  defp generate_or_fetch_narrative(task_id, user_id, force) do
    with {:ok, task} <- fetch_task(task_id, user_id),
         {:ok, project} <- fetch_project(task, user_id),
         task_context <- GtdBridgeClient.build_task_context(task, project, user_id),
         input_hash <- GtdBridgeClient.calculate_input_hash(task_context),
         quest_type <- classify_quest(task) do
      if force do
        Logger.info("Force refresh: generating new narrative for task #{task_id}")
        generate_narrative(task_context, input_hash, user_id, quest_type, task)
      else
        case NarrativeCache.get_cached(task_id, input_hash) do
          {:hit, cached_narrative} ->
            Logger.info("Cache hit for task #{task_id}")
            {:ok, cached_narrative, "cached", quest_type, task}

          {:miss, reason} ->
            Logger.info("Cache miss for task #{task_id} (#{reason})")
            generate_narrative(task_context, input_hash, user_id, quest_type, task)
        end
      end
    else
      {:error, reason} ->
        Logger.error("Failed to fetch task/project context: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_task(task_id, user_id) do
    case GtdBridgeClient.get_task(task_id, user_id) do
      {:ok, response} ->
        task = response["data"] || response
        {:ok, task}

      {:error, reason} ->
        Logger.error("Failed to fetch task #{task_id}: #{inspect(reason)}")
        {:error, {:fetch_task_failed, reason}}
    end
  end

  defp fetch_project(task, user_id) do
    project_id = task["project_id"] || task["project"]

    if project_id do
      case GtdBridgeClient.get_project(project_id, user_id) do
        {:ok, response} ->
          project = response["data"] || response
          {:ok, project}

        {:error, reason} ->
          Logger.warning("Failed to fetch project #{project_id}: #{inspect(reason)}")
          # Fallback to empty project if fetch fails
          {:ok, %{"id" => project_id, "name" => "Unknown", "goal" => ""}}
      end
    else
      {:ok, %{"name" => "Unassigned", "goal" => ""}}
    end
  end

  defp generate_narrative(task_context, input_hash, _user_id, quest_type, task) do
    Logger.info(
      "Generating new narrative for task #{task_context["task_id"]} (type: #{quest_type})"
    )

    case NarrativeLlm.generate_narrative(task_context, quest_type) do
      {:ok, narrative} ->
        Logger.info("Narrative generated successfully")

        # Cache it
        NarrativeCache.put_cached(
          task_context["task_id"],
          narrative,
          task_context,
          input_hash
        )

        {:ok, narrative, "llm_bot", quest_type, task}

      {:error, reason} ->
        Logger.error("LLM generation failed: #{inspect(reason)}")

        # Fallback to template-based generation
        Logger.info("Falling back to template generation")

        narrative = %{
          "quest_title" => generate_fallback_quest_title(task_context),
          "scene_flavor" => generate_fallback_scene_flavor(task_context),
          "beat_next" => "Begin with one small action.",
          "emotional_frame" => select_emotional_frame(task_context)
        }

        NarrativeCache.put_cached(
          task_context["task_id"],
          narrative,
          task_context,
          input_hash
        )

        {:ok, narrative, "fallback", quest_type, task}
    end
  end

  defp classify_quest(task) do
    title = task["title"] || ""
    description = task["description"]
    tags = task["tags"] || []

    QuestTypeClassifier.classify(title, description, tags)
  end

  # Fallback template-based generation when LLM fails
  defp generate_fallback_quest_title(context) do
    "#{context["task_title"]} awaits"
  end

  defp generate_fallback_scene_flavor(context) do
    energy = context["energy_level"]
    time = context["time_of_day"]

    case {energy, time} do
      {e, _} when e >= 8 ->
        "The moment is bright. Energy flows. This is when you move."

      {e, "dawn"} when e < 5 ->
        "Dawn breaks quietly. The world is still. You stir."

      {_, "night"} ->
        "Night deepens. The world is quiet. Thoughts become clear."

      _ ->
        "The world waits. Your next step is there, ready."
    end
  end

  defp select_emotional_frame(context) do
    energy = context["energy_level"]
    consecutive = context["streak"]["consecutive_days"]
    broken_days = context["streak"]["days_since_broken"]

    cond do
      energy >= 8 and consecutive > 0 -> "hopeful"
      energy >= 8 -> "playful"
      energy >= 5 and consecutive > 0 -> "tender"
      energy >= 5 -> "weary_but_moving"
      energy >= 2 and broken_days > 0 -> "melancholic_resolve"
      true -> "defiant"
    end
  end

  defp valid_until do
    DateTime.utc_now()
    |> DateTime.add(12 * 3600, :second)
    |> DateTime.to_iso8601()
  end

  defp publish_reply(reply_to, response) do
    case Jason.encode(response) do
      {:ok, json} ->
        Publisher.publish(reply_to, json)
        Logger.debug("Published narrative response to #{reply_to}")

      {:error, reason} ->
        Logger.error("Failed to encode narrative response: #{inspect(reason)}")
    end
  end
end
