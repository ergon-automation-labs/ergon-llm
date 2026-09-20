defmodule BotArmyLlm.Services.ContextAwareVoiceRouterTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.{ContextAwareVoiceRouter, UserPreferences, VoicePreset}

  describe "route_voice/4" do
    test "routes self-care quests to nurturing aftercare" do
      prefs = UserPreferences.default()

      maintenance_voice = ContextAwareVoiceRouter.route_voice(:maintenance, 3, "tender", prefs)
      reflection_voice = ContextAwareVoiceRouter.route_voice(:reflection, 2, "hopeful", prefs)
      creation_voice = ContextAwareVoiceRouter.route_voice(:creation, 4, "playful", prefs)

      assert maintenance_voice == :nurturing_aftercare
      assert reflection_voice == :nurturing_aftercare
      assert creation_voice == :nurturing_aftercare
    end

    test "routes hard accountability quests to commanding authority" do
      prefs = UserPreferences.default()

      hard_combat = ContextAwareVoiceRouter.route_voice(:combat, 8, "defiant", prefs)

      hard_exploration =
        ContextAwareVoiceRouter.route_voice(:exploration, 7, "weary_but_moving", prefs)

      assert hard_combat == :commanding_authority
      assert hard_exploration == :commanding_authority
    end

    test "uses user preference for easy accountability quests" do
      prefs = UserPreferences.set_voice(UserPreferences.default(), :cheerleader)

      easy_combat = ContextAwareVoiceRouter.route_voice(:combat, 3, "playful", prefs)
      easy_exploration = ContextAwareVoiceRouter.route_voice(:exploration, 2, "hopeful", prefs)

      assert easy_combat == :cheerleader
      assert easy_exploration == :cheerleader
    end
  end

  describe "context_override/3" do
    test "returns nurturing_aftercare for maintenance" do
      override = ContextAwareVoiceRouter.context_override(:maintenance, 5, "tender")
      assert override == :nurturing_aftercare
    end

    test "returns nurturing_aftercare for reflection" do
      override = ContextAwareVoiceRouter.context_override(:reflection, 3, "hopeful")
      assert override == :nurturing_aftercare
    end

    test "returns nurturing_aftercare for creation" do
      override = ContextAwareVoiceRouter.context_override(:creation, 5, "playful")
      assert override == :nurturing_aftercare
    end

    test "returns commanding_authority for hard combat" do
      override = ContextAwareVoiceRouter.context_override(:combat, 8, "defiant")
      assert override == :commanding_authority
    end

    test "returns commanding_authority for hard exploration" do
      override = ContextAwareVoiceRouter.context_override(:exploration, 7, "melancholic_resolve")
      assert override == :commanding_authority
    end

    test "returns nil for easy accountability quests" do
      override = ContextAwareVoiceRouter.context_override(:combat, 3, "playful")
      assert override == nil

      override = ContextAwareVoiceRouter.context_override(:exploration, 5, "hopeful")
      assert override == nil
    end
  end

  describe "routing_reason/2" do
    test "returns reason for nurturing_aftercare" do
      reason = ContextAwareVoiceRouter.routing_reason(:maintenance, :nurturing_aftercare)
      assert String.contains?(reason, "Self-care")
    end

    test "returns reason for commanding_authority" do
      reason = ContextAwareVoiceRouter.routing_reason(:combat, :commanding_authority)
      assert String.contains?(reason, "Hard work")
    end

    test "returns default reason for user preference" do
      reason = ContextAwareVoiceRouter.routing_reason(:combat, :cheerleader)
      assert String.contains?(reason, "preferred voice")
    end
  end

  describe "new voices in VoicePreset" do
    test "commanding_authority preset exists" do
      voice = VoicePreset.get_preset(:commanding_authority)
      assert voice.key == :commanding_authority
      assert voice.challenge == 10
      assert voice.support == 2
    end

    test "nurturing_aftercare preset exists" do
      voice = VoicePreset.get_preset(:nurturing_aftercare)
      assert voice.key == :nurturing_aftercare
      assert voice.support == 10
      assert voice.warmth == 10
    end

    test "new voices appear in all_presets" do
      all = VoicePreset.all_presets()
      keys = Enum.map(all, & &1.key)

      assert :commanding_authority in keys
      assert :nurturing_aftercare in keys
    end

    test "voice names are properly set" do
      assert VoicePreset.voice_name(:commanding_authority) == "Commanding Authority"
      assert VoicePreset.voice_name(:nurturing_aftercare) == "Nurturing Aftercare"
    end
  end
end
