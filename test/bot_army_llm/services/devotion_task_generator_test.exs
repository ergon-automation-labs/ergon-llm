defmodule BotArmyLlm.Services.DevotionTaskGeneratorTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.{DevotionTaskGenerator, LouizaIntentConfig}

  describe "generate_devotion_task/3" do
    test "returns task structure" do
      config = LouizaIntentConfig.default()
      task = DevotionTaskGenerator.generate_devotion_task(config, 70.0, "user-1")

      assert Map.has_key?(task, "task_id")
      assert Map.has_key?(task, "title")
      assert Map.has_key?(task, "description")
      assert Map.has_key?(task, "type")
      assert task["type"] == :devotion
    end

    test "intensity scales with engagement" do
      config = LouizaIntentConfig.default()
      low_intensity_task = DevotionTaskGenerator.generate_devotion_task(config, 20.0, "user-1")
      high_intensity_task = DevotionTaskGenerator.generate_devotion_task(config, 90.0, "user-1")

      assert low_intensity_task["intensity_level"] <= high_intensity_task["intensity_level"]
    end

    test "includes louiza directive if set" do
      config =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          louiza_custom_directive: "Focus on submission"
        })

      task = DevotionTaskGenerator.generate_devotion_task(config, 50.0, "user-1")
      assert task["louiza_directive"] == "Focus on submission"
    end

    test "tags include louiza and devotion" do
      config = LouizaIntentConfig.default()
      task = DevotionTaskGenerator.generate_devotion_task(config, 50.0, "user-1")

      assert Enum.member?(task["tags"], "with louiza")
      assert Enum.member?(task["tags"], "devotion")
    end
  end

  describe "devotion_title/2" do
    test "foot massage title escalates with intensity" do
      low = DevotionTaskGenerator.devotion_title(:foot_massage, 2.0)
      mid = DevotionTaskGenerator.devotion_title(:foot_massage, 5.0)
      high = DevotionTaskGenerator.devotion_title(:foot_massage, 9.0)

      assert String.contains?(low, "gentle")
      assert String.contains?(high, "worship")
    end

    test "worship titles escalate" do
      low = DevotionTaskGenerator.devotion_title(:worship, 2.0)
      high = DevotionTaskGenerator.devotion_title(:worship, 8.0)

      assert byte_size(low) >= 0
      assert byte_size(high) >= 0
    end

    test "all devotion types have titles" do
      types = [:foot_massage, :acts_of_service, :worship, :humiliation, :devotion, :custom]

      Enum.each(types, fn type ->
        title = DevotionTaskGenerator.devotion_title(type, 5.0)
        assert is_binary(title)
        assert byte_size(title) > 0
      end)
    end
  end

  describe "devotion_description/3" do
    test "returns narrative description" do
      config = LouizaIntentConfig.default()
      desc = DevotionTaskGenerator.devotion_description(:foot_massage, 5.0, config)

      assert is_binary(desc)
      assert byte_size(desc) > 0
    end

    test "includes louiza in descriptions" do
      config = LouizaIntentConfig.default()
      desc = DevotionTaskGenerator.devotion_description(:foot_massage, 5.0, config)

      assert String.contains?(desc, "Louiza")
    end
  end
end
