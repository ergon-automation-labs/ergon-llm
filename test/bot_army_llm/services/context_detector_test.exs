defmodule BotArmyLlm.Services.ContextDetectorTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.ContextDetector

  describe "detect/1" do
    test "returns context map with all fields" do
      task = %{"title" => "Shower", "tags" => ["bathroom"]}

      context = ContextDetector.detect(task)

      assert Map.has_key?(context, "location")
      assert Map.has_key?(context, "time_period")
      assert Map.has_key?(context, "presence")
      assert Map.has_key?(context, "energy_level")
      assert Map.has_key?(context, "intensity")
    end
  end

  describe "detect_location/1" do
    test "detects bathroom from tags" do
      task = %{"tags" => ["bathroom", "hygiene"]}
      assert ContextDetector.detect_location(task) == :bathroom
    end

    test "detects kitchen from tags" do
      task = %{"tags" => ["kitchen", "meal"]}
      assert ContextDetector.detect_location(task) == :kitchen
    end

    test "detects gym from tags" do
      task = %{"tags" => ["gym", "exercise"]}
      assert ContextDetector.detect_location(task) == :gym
    end

    test "detects bedroom from tags" do
      task = %{"tags" => ["bedroom", "sleep"]}
      assert ContextDetector.detect_location(task) == :bedroom
    end

    test "detects work from tags" do
      task = %{"tags" => ["work", "code"]}
      assert ContextDetector.detect_location(task) == :work
    end

    test "detects from description" do
      task = %{"title" => "Exercise", "description" => "Go to the gym"}
      assert ContextDetector.detect_location(task) == :gym
    end

    test "returns unknown for untagged task" do
      task = %{"title" => "Do something"}
      assert ContextDetector.detect_location(task) == :unknown
    end
  end

  describe "detect_time_period/1" do
    test "returns atom" do
      task = %{}
      period = ContextDetector.detect_time_period(task)
      assert is_atom(period)
      assert period in [:morning, :afternoon, :evening, :night]
    end

    test "respects task metadata" do
      task = %{"time_period" => "morning"}
      assert ContextDetector.detect_time_period(task) == :morning
    end
  end

  describe "detect_presence/1" do
    test "detects alone" do
      task = %{"collaborators" => [], "tags" => []}
      assert ContextDetector.detect_presence(task) == :alone
    end

    test "detects with partner from louiza mention" do
      task = %{"tags" => ["with louiza"]}
      assert ContextDetector.detect_presence(task) == :with_partner
    end

    test "detects with one collaborator" do
      task = %{"collaborators" => ["louiza"]}
      assert ContextDetector.detect_presence(task) == :with_partner
    end

    test "detects group with multiple collaborators" do
      task = %{"collaborators" => ["louiza", "friend"]}
      assert ContextDetector.detect_presence(task) == :group
    end
  end

  describe "detect_energy/1" do
    test "high energy" do
      task = %{"energy_level" => 8}
      assert ContextDetector.detect_energy(task) == :high
    end

    test "medium energy" do
      task = %{"energy_level" => 5}
      assert ContextDetector.detect_energy(task) == :medium
    end

    test "low energy" do
      task = %{"energy_level" => 2}
      assert ContextDetector.detect_energy(task) == :low
    end
  end

  describe "detect_intensity/1" do
    test "high intensity for long physical activity" do
      task = %{"estimated_duration" => 60, "tags" => ["exercise"]}
      assert ContextDetector.detect_intensity(task) == :high
    end

    test "high intensity for long duration" do
      task = %{"estimated_duration" => 90}
      assert ContextDetector.detect_intensity(task) == :high
    end

    test "medium intensity for moderate duration" do
      task = %{"estimated_duration" => 45}
      assert ContextDetector.detect_intensity(task) == :medium
    end

    test "low intensity for short task" do
      task = %{"estimated_duration" => 10}
      assert ContextDetector.detect_intensity(task) == :low
    end
  end

  describe "is_self_care_location?/1" do
    test "identifies self-care locations" do
      assert ContextDetector.is_self_care_location?(:bathroom) == true
      assert ContextDetector.is_self_care_location?(:bedroom) == true
      assert ContextDetector.is_self_care_location?(:couch) == true
      assert ContextDetector.is_self_care_location?(:gym) == false
      assert ContextDetector.is_self_care_location?(:kitchen) == false
    end
  end

  describe "is_activity_location?/1" do
    test "identifies activity locations" do
      assert ContextDetector.is_activity_location?(:gym) == true
      assert ContextDetector.is_activity_location?(:kitchen) == true
      assert ContextDetector.is_activity_location?(:bathroom) == false
      assert ContextDetector.is_activity_location?(:bedroom) == false
    end
  end
end
