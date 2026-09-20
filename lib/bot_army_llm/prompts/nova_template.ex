defmodule BotArmyLlm.Prompts.NovaTemplate do
  @moduledoc """
  Prompt template for Nova narrative generation.

  Generates evocative story text for tasks based on:
  - Task title and project goal
  - Time of day (circadian framing)
  - Energy level (1-10)
  - Streak metrics (consecutive days, days since broken)
  """

  @system_prompt """
  You are Nova, the narrative voice of a visual novel task manager.
  Generate evocative, brief narrative text for quests (GTD tasks).
  Your role: frame mundane tasks as story beats, make failure safe, celebrate small wins.

  Constraints:
  - quest_title: 5-10 words, poetic but clear
  - scene_flavor: 1-2 sentences, vivid sensory detail
  - beat_next: 1 sentence, tiny first step (not intimidating)
  - emotional_frame: choose from: hopeful|melancholic_resolve|playful|defiant|tender|weary_but_moving

  Output ONLY valid JSON with these exact keys, no markdown code blocks.
  """

  def system_prompt, do: @system_prompt

  def build_prompt(task_context) do
    """
    Task: #{task_context.task_title}
    Project: #{task_context.project_name} - #{task_context.project_goal}

    Context:
    - Time: #{task_context.time_of_day} (#{task_context.hour}:00)
    - Energy: #{task_context.energy_level} / 10
    - Streak: #{streak_description(task_context.streak)}

    Generate narrative as JSON with keys: quest_title, scene_flavor, beat_next, emotional_frame.
    """
  end

  defp streak_description(streak) do
    case streak do
      %{"consecutive_days" => days} when days > 0 ->
        "on a #{days}-day winning streak"

      %{"days_since_broken" => days} when days > 0 ->
        "broken #{days} days ago"

      _ ->
        "no active streak"
    end
  end

  # Emotional frame selection based on energy and context
  def select_emotional_frame(energy_level, time_of_day, streak_status) do
    cond do
      energy_level >= 8 and streak_status == :active ->
        "hopeful"

      energy_level >= 8 ->
        "playful"

      energy_level >= 5 and streak_status == :active ->
        "tender"

      energy_level >= 5 ->
        "weary_but_moving"

      energy_level >= 2 and streak_status == :broken ->
        "melancholic_resolve"

      time_of_day in ["dawn", "late_night"] ->
        "defiant"

      true ->
        "weary_but_moving"
    end
  end

  # Time of day classification for narrative context
  def classify_time_of_day(hour) do
    cond do
      hour >= 4 and hour < 7 -> "dawn"
      hour >= 7 and hour < 10 -> "morning"
      hour >= 10 and hour < 12 -> "late_morning"
      hour >= 12 and hour < 15 -> "midday"
      hour >= 15 and hour < 17 -> "afternoon"
      hour >= 17 and hour < 20 -> "evening"
      hour >= 20 and hour < 23 -> "night"
      true -> "late_night"
    end
  end

  # Energy calculation formula
  def calculate_energy_level(base_energy, streak_days, days_since_broken, completions_today) do
    base = base_energy

    # Boost from winning streak (max +3)
    streak_boost =
      if streak_days > 0 do
        min(div(streak_days, 10), 3)
      else
        0
      end

    # Penalty from silence (max -3)
    silence_penalty =
      if days_since_broken > 0 do
        -min(div(days_since_broken, 20), 3)
      else
        0
      end

    # Boost from today's completions (+1 if any)
    today_boost =
      if completions_today > 0 do
        1
      else
        0
      end

    # Clamp to 1-10
    energy = base + streak_boost + silence_penalty + today_boost
    max(1, min(energy, 10))
  end

  # Time-of-day base energy (circadian)
  def base_energy_for_time(time_of_day) do
    case time_of_day do
      "dawn" -> 2
      "morning" -> 7
      "late_morning" -> 8
      "midday" -> 6
      "afternoon" -> 4
      "evening" -> 5
      "night" -> 3
      "late_night" -> 2
      _ -> 5
    end
  end
end
