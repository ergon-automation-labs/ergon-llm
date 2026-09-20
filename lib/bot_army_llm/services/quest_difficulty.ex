defmodule BotArmyLlm.Services.QuestDifficulty do
  @moduledoc """
  Calculate quest difficulty (1-10 HP for boss fights).

  Difficulty is based on:
  - Estimated duration
  - Task complexity (inferred from keywords)
  - Subtask count
  - Project scope
  """

  @type difficulty :: 1..10

  @doc """
  Calculate difficulty rating for a quest.

  Returns 1-10 where 1 = trivial, 10 = epic.
  """
  @spec calculate(map()) :: difficulty()
  def calculate(task) when is_map(task) do
    base_difficulty = estimate_from_duration(task["estimated_duration_minutes"])
    complexity_boost = estimate_from_keywords(task["title"], task["description"])
    subtask_penalty = estimate_from_subtasks(task["subtasks"])

    (base_difficulty + complexity_boost + subtask_penalty)
    |> min(10)
    |> max(1)
  end

  @doc """
  Convert difficulty to HP for boss fight.

  HP scales from 3 (trivial) to 100 (epic).
  """
  @spec difficulty_to_hp(difficulty()) :: integer()
  def difficulty_to_hp(difficulty) do
    # Linear scale: difficulty 1 = 10 HP, difficulty 10 = 100 HP
    10 * difficulty
  end

  @doc """
  Convert task progress (0-100%) to HP remaining.

  As you complete % of task, boss takes damage.
  """
  @spec hp_remaining(difficulty(), integer()) :: integer()
  def hp_remaining(difficulty, progress_percent) do
    max_hp = difficulty_to_hp(difficulty)
    damage_taken = div(max_hp * progress_percent, 100)
    max(1, max_hp - damage_taken)
  end

  # Private helpers

  defp estimate_from_duration(nil), do: 2
  defp estimate_from_duration(minutes) when minutes < 15, do: 1
  defp estimate_from_duration(minutes) when minutes < 30, do: 2
  defp estimate_from_duration(minutes) when minutes < 60, do: 3
  defp estimate_from_duration(minutes) when minutes < 120, do: 5
  defp estimate_from_duration(minutes) when minutes < 240, do: 7
  defp estimate_from_duration(_minutes), do: 9

  defp estimate_from_keywords(title, description) do
    text = "#{title} #{description || ""}" |> String.downcase()

    complex_keywords = [
      "refactor",
      "redesign",
      "migrate",
      "integrate",
      "architecture",
      "debug",
      "investigate",
      "optimize",
      "rewrite",
      "overhaul"
    ]

    if Enum.any?(complex_keywords, &String.contains?(text, &1)), do: 2, else: 0
  end

  defp estimate_from_subtasks(nil), do: 0

  defp estimate_from_subtasks(subtasks) when is_list(subtasks) do
    count = length(subtasks)

    cond do
      count < 3 -> 0
      count < 6 -> 1
      count < 10 -> 2
      true -> 3
    end
  end

  defp estimate_from_subtasks(_), do: 0
end
