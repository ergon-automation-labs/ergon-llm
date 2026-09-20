defmodule BotArmyLlm.Services.AllianceSystemTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.AllianceSystem

  describe "allies_from_task/1" do
    test "extracts explicit collaborators" do
      task = %{
        "title" => "Pair programming session",
        "collaborators" => [
          %{"name" => "Alice", "strength" => 7},
          %{"name" => "Bob", "strength" => 6}
        ]
      }

      allies = AllianceSystem.allies_from_task(task)
      assert length(allies) >= 2
      assert Enum.any?(allies, &(&1.name == "Alice"))
    end

    test "handles empty collaborators" do
      task = %{
        "title" => "Solo task",
        "description" => "Work alone on this",
        "collaborators" => []
      }

      allies = AllianceSystem.allies_from_task(task)
      assert is_list(allies)
    end

    test "extracts implicit allies from description" do
      task = %{
        "title" => "Team meeting",
        "description" => "Meet with the team to discuss",
        "collaborators" => []
      }

      allies = AllianceSystem.allies_from_task(task)
      assert is_list(allies)
    end
  end

  describe "combined_strength/1" do
    test "returns 1 for empty alliance" do
      strength = AllianceSystem.combined_strength([])
      assert strength == 1
    end

    test "returns ally strength for single ally" do
      allies = [%{name: "Alice", strength: 7, role: "partner"}]
      strength = AllianceSystem.combined_strength(allies)
      assert strength == 7
    end

    test "averages and boosts for multiple allies" do
      allies = [
        %{name: "Alice", strength: 6, role: "partner"},
        %{name: "Bob", strength: 8, role: "partner"}
      ]

      strength = AllianceSystem.combined_strength(allies)
      assert strength > 6 and strength <= 10
    end

    test "caps at 10" do
      allies =
        Enum.map(1..10, fn i ->
          %{name: "Person#{i}", strength: 10, role: "ally"}
        end)

      strength = AllianceSystem.combined_strength(allies)
      assert strength == 10
    end
  end

  describe "morale/1" do
    test "returns solo for no allies" do
      morale = AllianceSystem.morale([])
      assert morale == "solo"
    end

    test "returns strong_ally for strong single ally" do
      allies = [%{name: "Strong", strength: 8, role: "ally"}]
      morale = AllianceSystem.morale(allies)
      assert morale == "strong_ally"
    end

    test "returns formidable_force for large strong team" do
      allies =
        Enum.map(1..4, fn i ->
          %{name: "Person#{i}", strength: 8, role: "ally"}
        end)

      morale = AllianceSystem.morale(allies)
      assert morale == "formidable_force"
    end

    test "returns united for moderate team" do
      allies =
        Enum.map(1..3, fn i ->
          %{name: "Person#{i}", strength: 5, role: "ally"}
        end)

      morale = AllianceSystem.morale(allies)
      assert morale == "united"
    end
  end

  describe "morale_phrase/1" do
    test "returns phrase for each morale state" do
      states = [
        "solo",
        "strong_ally",
        "single_companion",
        "formidable_force",
        "united",
        "powerful_team",
        "determined_group"
      ]

      Enum.each(states, fn state ->
        phrase = AllianceSystem.morale_phrase(state)
        assert is_binary(phrase)
        assert String.length(phrase) > 0
      end)
    end
  end

  describe "collaboration_prompts/1" do
    test "returns prompts for solo" do
      prompts = AllianceSystem.collaboration_prompts([])
      assert is_list(prompts)
      assert length(prompts) > 0
      assert Enum.all?(prompts, &is_binary/1)
    end

    test "returns prompts for duo" do
      allies = [%{name: "Friend", strength: 6, role: "ally"}]
      prompts = AllianceSystem.collaboration_prompts(allies)
      assert is_list(prompts)
      assert length(prompts) > 0
    end

    test "returns prompts for team" do
      allies =
        Enum.map(1..3, fn i ->
          %{name: "Person#{i}", strength: 5, role: "ally"}
        end)

      prompts = AllianceSystem.collaboration_prompts(allies)
      assert is_list(prompts)
      assert length(prompts) > 0
    end
  end

  describe "format_allies/1" do
    test "returns 'Standing alone' for empty" do
      formatted = AllianceSystem.format_allies([])
      assert formatted == "Standing alone"
    end

    test "returns name for single ally" do
      allies = [%{name: "Alice", strength: 5, role: "ally"}]
      formatted = AllianceSystem.format_allies(allies)
      assert String.contains?(formatted, "Alice")
    end

    test "returns comma-separated list for multiple" do
      allies = [
        %{name: "Alice", strength: 5, role: "ally"},
        %{name: "Bob", strength: 6, role: "ally"}
      ]

      formatted = AllianceSystem.format_allies(allies)
      assert String.contains?(formatted, "Alice")
      assert String.contains?(formatted, "Bob")
      assert String.contains?(formatted, ",")
    end
  end
end
