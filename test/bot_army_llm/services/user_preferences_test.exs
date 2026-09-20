defmodule BotArmyLlm.Services.UserPreferencesTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.UserPreferences

  describe "default/0" do
    test "returns default preferences" do
      prefs = UserPreferences.default()
      assert prefs.voice_key == :disappointed_narrator
      assert is_nil(prefs.custom_warmth)
      assert is_nil(prefs.custom_sharpness)
    end
  end

  describe "set_voice/2" do
    test "sets voice key" do
      prefs = UserPreferences.default()
      updated = UserPreferences.set_voice(prefs, :cheerleader)
      assert updated.voice_key == :cheerleader
    end

    test "clears custom settings when changing voice" do
      prefs = %{
        voice_key: :custom,
        custom_warmth: 8,
        custom_sharpness: 3,
        custom_humor: 7,
        custom_challenge: 4,
        custom_support: 9,
        updated_at: DateTime.utc_now()
      }

      updated = UserPreferences.set_voice(prefs, :drill_sergeant)
      assert updated.voice_key == :drill_sergeant
      assert is_nil(updated.custom_warmth)
      assert is_nil(updated.custom_sharpness)
    end
  end

  describe "customize_voice/2" do
    test "sets voice to custom and applies customizations" do
      prefs = UserPreferences.default()
      customizations = %{"warmth" => 9, "sharpness" => 2, "humor" => 6}
      updated = UserPreferences.customize_voice(prefs, customizations)
      assert updated.voice_key == :custom
      assert updated.custom_warmth == 9
      assert updated.custom_sharpness == 2
      assert updated.custom_humor == 6
    end

    test "preserves existing customizations if not overridden" do
      prefs = %{
        voice_key: :custom,
        custom_warmth: 8,
        custom_sharpness: 5,
        custom_humor: 7,
        custom_challenge: 4,
        custom_support: 9,
        updated_at: DateTime.utc_now()
      }

      customizations = %{"warmth" => 9}
      updated = UserPreferences.customize_voice(prefs, customizations)
      assert updated.custom_warmth == 9
      assert updated.custom_sharpness == 5
    end
  end

  describe "get_effective_voice/1" do
    test "returns base voice for preset voices" do
      prefs = UserPreferences.default()
      voice = UserPreferences.get_effective_voice(prefs)
      assert voice.key == :disappointed_narrator
      assert voice.warmth == 7
    end

    test "applies customizations for custom voice" do
      prefs = %{
        voice_key: :custom,
        custom_warmth: 9,
        custom_sharpness: 2,
        custom_humor: nil,
        custom_challenge: nil,
        custom_support: nil,
        updated_at: DateTime.utc_now()
      }

      voice = UserPreferences.get_effective_voice(prefs)
      assert voice.warmth == 9
      assert voice.sharpness == 2
    end

    test "falls back to defaults for nil custom values" do
      prefs = %{
        voice_key: :custom,
        custom_warmth: 8,
        custom_sharpness: nil,
        custom_humor: nil,
        custom_challenge: nil,
        custom_support: nil,
        updated_at: DateTime.utc_now()
      }

      voice = UserPreferences.get_effective_voice(prefs)
      assert voice.warmth == 8
      assert voice.sharpness == 5
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trips preferences through JSON" do
      prefs = UserPreferences.default()
      encoded = UserPreferences.encode(prefs)
      assert is_binary(encoded)

      {:ok, decoded} = UserPreferences.decode(encoded)
      assert decoded.voice_key == prefs.voice_key
    end

    test "decode returns error for invalid JSON" do
      result = UserPreferences.decode("not valid json")
      assert result == :error
    end

    test "encodes custom preferences" do
      prefs = %{
        voice_key: :custom,
        custom_warmth: 8,
        custom_sharpness: 3,
        custom_humor: 7,
        custom_challenge: 4,
        custom_support: 9,
        updated_at: DateTime.utc_now()
      }

      encoded = UserPreferences.encode(prefs)
      {:ok, decoded} = UserPreferences.decode(encoded)
      assert decoded.voice_key == :custom
      assert decoded.custom_warmth == 8
    end
  end
end
