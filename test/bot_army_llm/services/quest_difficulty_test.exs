defmodule BotArmyLlm.Services.QuestDifficultyTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.QuestDifficulty

  describe "calculate/1" do
    test "trivial task (short duration, no complexity)" do
      task = %{
        "title" => "Reply to email",
        "description" => "Quick response",
        "estimated_duration_minutes" => 5,
        "subtasks" => []
      }

      difficulty = QuestDifficulty.calculate(task)
      assert difficulty >= 1
      assert difficulty <= 3
    end

    test "moderate task (medium duration)" do
      task = %{
        "title" => "Write report",
        "description" => "Quarterly summary",
        "estimated_duration_minutes" => 60,
        "subtasks" => [%{}, %{}, %{}]
      }

      difficulty = QuestDifficulty.calculate(task)
      assert difficulty >= 3
      assert difficulty <= 6
    end

    test "complex task (long duration, keywords, subtasks)" do
      task = %{
        "title" => "Refactor authentication system",
        "description" => "Migrate to new OAuth provider",
        "estimated_duration_minutes" => 300,
        "subtasks" => [%{}, %{}, %{}, %{}, %{}, %{}, %{}]
      }

      difficulty = QuestDifficulty.calculate(task)
      assert difficulty >= 7
      assert difficulty <= 10
    end

    test "respects 1-10 ceiling" do
      task = %{
        "title" => "Refactor the entire architecture",
        "estimated_duration_minutes" => 10000,
        "subtasks" => [%{}, %{}, %{}, %{}, %{}, %{}, %{}, %{}, %{}, %{}]
      }

      difficulty = QuestDifficulty.calculate(task)
      assert difficulty == 10
    end
  end

  describe "difficulty_to_hp/1" do
    test "converts difficulty to HP scale" do
      assert QuestDifficulty.difficulty_to_hp(1) == 10
      assert QuestDifficulty.difficulty_to_hp(5) == 50
      assert QuestDifficulty.difficulty_to_hp(10) == 100
    end
  end

  describe "hp_remaining/2" do
    test "calculates remaining HP as task progresses" do
      # Difficulty 5 = 50 HP
      assert QuestDifficulty.hp_remaining(5, 0) == 50
      assert QuestDifficulty.hp_remaining(5, 50) == 25
      assert QuestDifficulty.hp_remaining(5, 100) >= 1
    end

    test "never returns 0 HP (boss at 1 HP minimum)" do
      assert QuestDifficulty.hp_remaining(1, 100) >= 1
      assert QuestDifficulty.hp_remaining(10, 100) >= 1
    end
  end
end
