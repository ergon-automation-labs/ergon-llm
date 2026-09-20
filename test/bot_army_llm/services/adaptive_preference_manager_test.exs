defmodule BotArmyLlm.Services.AdaptivePreferenceManagerTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.{AdaptivePreferenceManager, UserPreferences}

  describe "voice_name/1 helper" do
    test "returns human-readable names for preset voices" do
      assert UserPreferences.voice_name(:disappointed_narrator) == "Disappointed Narrator"
      assert UserPreferences.voice_name(:cheerleader) == "Cheerleader"
      assert UserPreferences.voice_name(:drill_sergeant) == "Drill Sergeant"
      assert UserPreferences.voice_name(:gentle_guide) == "Gentle Guide"
      assert UserPreferences.voice_name(:mythic_oracle) == "Mythic Oracle"
      assert UserPreferences.voice_name(:custom) == "Custom Voice"
    end
  end

  describe "AdaptivePreferenceManager initialization" do
    test "module is available and compilable" do
      assert Code.ensure_loaded?(AdaptivePreferenceManager)
    end
  end

  describe "integration with UserPreferences" do
    test "can create default preferences" do
      prefs = UserPreferences.default()
      assert prefs.voice_key == :disappointed_narrator
    end

    test "can set voice in preferences" do
      prefs = UserPreferences.default()
      updated = UserPreferences.set_voice(prefs, :cheerleader)
      assert updated.voice_key == :cheerleader
    end

    test "can get voice name for preferences" do
      prefs = UserPreferences.default()
      name = UserPreferences.voice_name(prefs.voice_key)
      assert name == "Disappointed Narrator"
    end
  end
end
