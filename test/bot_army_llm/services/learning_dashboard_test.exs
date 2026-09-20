defmodule BotArmyLlm.Services.LearningDashboardTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.{LearningDashboard, UserPreferences}

  describe "LearningDashboard module" do
    test "is available and compilable" do
      assert Code.ensure_loaded?(LearningDashboard)
    end
  end

  describe "voice_name integration" do
    test "voice names are properly formatted" do
      prefs = UserPreferences.default()

      voice_name = UserPreferences.voice_name(prefs.voice_key)

      assert voice_name == "Disappointed Narrator"
      assert is_binary(voice_name)
    end

    test "all preset voices have names" do
      voices = [
        :disappointed_narrator,
        :cheerleader,
        :drill_sergeant,
        :gentle_guide,
        :mythic_oracle
      ]

      Enum.each(voices, fn voice ->
        name = UserPreferences.voice_name(voice)
        assert is_binary(name)
        assert String.length(name) > 0
      end)
    end
  end

  describe "UserPreferences default creation" do
    test "creates default preferences" do
      prefs = UserPreferences.default()

      assert prefs.voice_key == :disappointed_narrator
      assert prefs.custom_warmth == nil
      assert Map.has_key?(prefs, :updated_at)
    end

    test "can set voice" do
      prefs = UserPreferences.default()
      updated = UserPreferences.set_voice(prefs, :cheerleader)

      assert updated.voice_key == :cheerleader
    end

    test "can customize voice parameters" do
      prefs = UserPreferences.default()
      customizations = %{"warmth" => 8, "humor" => 7}
      custom = UserPreferences.customize_voice(prefs, customizations)

      assert custom.voice_key == :custom
      assert custom.custom_warmth == 8
      assert custom.custom_humor == 7
    end
  end
end
