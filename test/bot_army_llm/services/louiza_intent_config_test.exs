defmodule BotArmyLlm.Services.LouizaIntentConfigTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.LouizaIntentConfig

  describe "default/0" do
    test "returns default intent config" do
      config = LouizaIntentConfig.default()

      assert config.intensity_level == 5
      assert config.devotion_type == :foot_massage
      assert config.escalation_curve == :linear
      assert config.punishment_intensity == :moderate
      assert config.current_multiplier == 1.0
    end
  end

  describe "set_intent/2" do
    test "updates intensity level" do
      config = LouizaIntentConfig.default()
      updated = LouizaIntentConfig.set_intent(config, %{intensity_level: 8})

      assert updated.intensity_level == 8
      assert updated.devotion_type == :foot_massage
    end

    test "updates devotion type" do
      config = LouizaIntentConfig.default()
      updated = LouizaIntentConfig.set_intent(config, %{devotion_type: :worship})

      assert updated.devotion_type == :worship
    end

    test "updates escalation curve" do
      config = LouizaIntentConfig.default()
      updated = LouizaIntentConfig.set_intent(config, %{escalation_curve: :aggressive})

      assert updated.escalation_curve == :aggressive
    end

    test "updates custom directive" do
      config = LouizaIntentConfig.default()

      updated =
        LouizaIntentConfig.set_intent(config, %{
          louiza_custom_directive: "Focus on humiliation"
        })

      assert updated.louiza_custom_directive == "Focus on humiliation"
    end
  end

  describe "escalate_intensity/2" do
    test "linear curve with high engagement" do
      config = LouizaIntentConfig.default()
      escalated = LouizaIntentConfig.escalate_intensity(config, 90.0)

      assert escalated > config.current_multiplier
    end

    test "exponential curve with high engagement" do
      config =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          escalation_curve: :exponential
        })

      escalated = LouizaIntentConfig.escalate_intensity(config, 90.0)
      assert escalated > config.current_multiplier
    end

    test "aggressive curve escalates more" do
      config_conservative =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          escalation_curve: :conservative
        })

      config_aggressive =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          escalation_curve: :aggressive
        })

      escalated_conservative =
        LouizaIntentConfig.escalate_intensity(config_conservative, 80.0)

      escalated_aggressive =
        LouizaIntentConfig.escalate_intensity(config_aggressive, 80.0)

      assert escalated_aggressive > escalated_conservative
    end

    test "caps at 10.0" do
      config =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          current_multiplier: 9.5,
          escalation_curve: :exponential
        })

      escalated = LouizaIntentConfig.escalate_intensity(config, 100.0)
      assert escalated <= 10.0
    end
  end

  describe "devotion_description/1" do
    test "foot massage has description" do
      desc = LouizaIntentConfig.devotion_description(:foot_massage)
      assert String.contains?(desc, "feet") or String.contains?(desc, "Feet")
    end

    test "worship has description" do
      desc = LouizaIntentConfig.devotion_description(:worship)
      assert String.contains?(desc, "worship") or String.contains?(desc, "Worship")
    end

    test "all devotion types have descriptions" do
      types = [:foot_massage, :acts_of_service, :worship, :humiliation, :devotion, :custom]

      Enum.each(types, fn type ->
        desc = LouizaIntentConfig.devotion_description(type)
        assert is_binary(desc)
        assert byte_size(desc) > 0
      end)
    end
  end

  describe "escalation_summary/1" do
    test "returns summary map" do
      config = LouizaIntentConfig.default()
      summary = LouizaIntentConfig.escalation_summary(config)

      assert Map.has_key?(summary, "current_intensity")
      assert Map.has_key?(summary, "escalation_multiplier")
      assert Map.has_key?(summary, "escalation_curve")
      assert Map.has_key?(summary, "devotion_focus")
      assert Map.has_key?(summary, "punishment_level")
    end
  end
end
