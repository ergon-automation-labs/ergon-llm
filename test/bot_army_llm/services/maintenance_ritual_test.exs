defmodule BotArmyLlm.Services.MaintenanceRitualTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.MaintenanceRitual

  describe "ritual_for_task/1" do
    test "identifies eat ritual from task" do
      task = %{
        "title" => "Eat lunch",
        "description" => "Proper meal",
        "estimated_duration_minutes" => 20
      }

      ritual = MaintenanceRitual.ritual_for_task(task)
      assert ritual["ritual_type"] == "eat"
      assert ritual["estimated_minutes"] == 20
    end

    test "identifies med ritual" do
      task = %{
        "title" => "Take vitamins",
        "description" => "Daily supplements",
        "estimated_duration_minutes" => 5
      }

      ritual = MaintenanceRitual.ritual_for_task(task)
      assert ritual["ritual_type"] == "med"
    end

    test "identifies move ritual" do
      task = %{
        "title" => "Go for a walk",
        "description" => "20 minute walk",
        "estimated_duration_minutes" => 20
      }

      ritual = MaintenanceRitual.ritual_for_task(task)
      assert ritual["ritual_type"] == "move"
    end

    test "identifies care ritual" do
      task = %{
        "title" => "Take a shower",
        "estimated_duration_minutes" => 15
      }

      ritual = MaintenanceRitual.ritual_for_task(task)
      assert ritual["ritual_type"] == "care"
    end

    test "identifies clean ritual" do
      task = %{
        "title" => "Wash dishes",
        "estimated_duration_minutes" => 10
      }

      ritual = MaintenanceRitual.ritual_for_task(task)
      assert ritual["ritual_type"] == "clean"
    end

    test "defaults to ritual for unknown type" do
      task = %{
        "title" => "Unknown task",
        "estimated_duration_minutes" => 30
      }

      ritual = MaintenanceRitual.ritual_for_task(task)
      assert ritual["ritual_type"] == "ritual"
      assert ritual["estimated_minutes"] == 30
    end
  end

  describe "phrase_for_type/1" do
    test "returns specific phrase for each ritual type" do
      assert String.contains?(MaintenanceRitual.phrase_for_type("eat"), "Nourishment")
      assert String.contains?(MaintenanceRitual.phrase_for_type("med"), "Medicine")
      assert String.contains?(MaintenanceRitual.phrase_for_type("move"), "Motion")
      assert String.contains?(MaintenanceRitual.phrase_for_type("care"), "love")
      assert String.contains?(MaintenanceRitual.phrase_for_type("clean"), "Order")
    end
  end

  describe "calculate_progress/2" do
    test "calculates progress for ritual in progress" do
      progress = MaintenanceRitual.calculate_progress(20, 300)
      assert progress["elapsed_seconds"] == 300
      assert progress["progress_percent"] == 25
      assert progress["time_remaining"] == 900
    end

    test "shows complete when elapsed >= estimated" do
      progress = MaintenanceRitual.calculate_progress(10, 600)
      assert progress["progress_percent"] == 100
      assert progress["time_remaining"] == :complete
    end

    test "clamps progress to 100%" do
      progress = MaintenanceRitual.calculate_progress(10, 1000)
      assert progress["progress_percent"] == 100
    end
  end

  describe "format_time/1" do
    test "formats seconds to human readable" do
      assert MaintenanceRitual.format_time(65) == "1m 5s"
      assert MaintenanceRitual.format_time(3661) == "61m 1s"
      assert MaintenanceRitual.format_time(45) == "45s"
    end

    test "formats complete marker" do
      assert MaintenanceRitual.format_time(:complete) == "Complete"
    end
  end

  describe "celebration_for_ritual/1" do
    test "returns celebration for each ritual type" do
      eat_msg = MaintenanceRitual.celebration_for_ritual("eat")
      assert String.contains?(eat_msg, "Fed")

      med_msg = MaintenanceRitual.celebration_for_ritual("med")
      assert String.contains?(med_msg, "steady")

      move_msg = MaintenanceRitual.celebration_for_ritual("move")
      assert String.contains?(move_msg, "Moved")
    end
  end

  describe "is_overdue?/2" do
    test "returns false when on time" do
      assert MaintenanceRitual.is_overdue?(10, 300) == false
    end

    test "returns false when within grace period" do
      # 10 minutes = 600 seconds, grace = 300 seconds (50%)
      assert MaintenanceRitual.is_overdue?(10, 800) == false
    end

    test "returns true when over grace period" do
      # 10 minutes = 600 seconds, grace = 300 seconds
      # 1000 seconds is > 900 (600 + 300)
      assert MaintenanceRitual.is_overdue?(10, 1000) == true
    end
  end
end
