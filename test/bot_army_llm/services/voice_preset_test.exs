defmodule BotArmyLlm.Services.VoicePresetTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.VoicePreset

  describe "all_presets/0" do
    test "returns all preset voices" do
      presets = VoicePreset.all_presets()
      assert is_list(presets)
      assert length(presets) == 7
    end

    test "each preset has required fields" do
      presets = VoicePreset.all_presets()

      Enum.each(presets, fn preset ->
        assert Map.has_key?(preset, :key)
        assert Map.has_key?(preset, :name)
        assert Map.has_key?(preset, :description)
        assert Map.has_key?(preset, :warmth)
        assert Map.has_key?(preset, :sharpness)
        assert Map.has_key?(preset, :humor)
        assert Map.has_key?(preset, :challenge)
        assert Map.has_key?(preset, :support)
      end)
    end
  end

  describe "get_preset/1" do
    test "returns disappointed narrator preset" do
      preset = VoicePreset.get_preset(:disappointed_narrator)
      assert preset.key == :disappointed_narrator
      assert preset.warmth == 7
      assert preset.challenge == 8
    end

    test "returns cheerleader preset" do
      preset = VoicePreset.get_preset(:cheerleader)
      assert preset.key == :cheerleader
      assert preset.warmth == 9
      assert preset.support == 10
    end

    test "returns drill sergeant preset" do
      preset = VoicePreset.get_preset(:drill_sergeant)
      assert preset.key == :drill_sergeant
      assert preset.sharpness == 9
      assert preset.challenge == 10
    end

    test "returns gentle guide preset" do
      preset = VoicePreset.get_preset(:gentle_guide)
      assert preset.key == :gentle_guide
      assert preset.warmth == 10
      assert preset.sharpness == 2
    end

    test "returns mythic oracle preset" do
      preset = VoicePreset.get_preset(:mythic_oracle)
      assert preset.key == :mythic_oracle
    end

    test "defaults to disappointed narrator for unknown key" do
      preset = VoicePreset.get_preset(:unknown)
      assert preset.key == :disappointed_narrator
    end
  end

  describe "voice_modifier/1" do
    test "returns modifier text for each voice" do
      presets = VoicePreset.all_presets()

      Enum.each(presets, fn preset ->
        modifier = VoicePreset.voice_modifier(preset)
        assert is_binary(modifier)
        assert String.length(modifier) > 0
      end)
    end

    test "disappointed narrator mentions caring" do
      preset = VoicePreset.get_preset(:disappointed_narrator)
      modifier = VoicePreset.voice_modifier(preset)
      assert String.contains?(modifier, "care")
    end

    test "cheerleader mentions excitement" do
      preset = VoicePreset.get_preset(:cheerleader)
      modifier = VoicePreset.voice_modifier(preset)
      assert String.contains?(modifier, "excited")
    end

    test "drill sergeant mentions directness" do
      preset = VoicePreset.get_preset(:drill_sergeant)
      modifier = VoicePreset.voice_modifier(preset)
      assert String.contains?(modifier, "direct")
    end
  end

  describe "voice_name/1" do
    test "returns name for each voice key" do
      keys = [
        :disappointed_narrator,
        :cheerleader,
        :drill_sergeant,
        :gentle_guide,
        :mythic_oracle
      ]

      Enum.each(keys, fn key ->
        name = VoicePreset.voice_name(key)
        assert is_binary(name)
        assert String.length(name) > 0
      end)
    end
  end

  describe "voice_description/1" do
    test "returns description for each voice key" do
      keys = [
        :disappointed_narrator,
        :cheerleader,
        :drill_sergeant,
        :gentle_guide,
        :mythic_oracle
      ]

      Enum.each(keys, fn key ->
        desc = VoicePreset.voice_description(key)
        assert is_binary(desc)
        assert String.length(desc) > 0
      end)
    end
  end
end
