defmodule BotArmyLlm.Services.UserPreferences do
  @moduledoc """
  User preferences for Nova voice and personalization.

  Stores user's selected voice and customization choices.
  In Phase 8, this is manual selection. In Phase 9, this learns from engagement.
  """

  alias BotArmyLlm.Services.VoicePreset

  @type preferences :: %{
          voice_key: atom(),
          custom_warmth: integer() | nil,
          custom_sharpness: integer() | nil,
          custom_humor: integer() | nil,
          custom_challenge: integer() | nil,
          custom_support: integer() | nil,
          updated_at: DateTime.t()
        }

  @doc """
  Create default preferences (Disappointed Narrator).
  """
  @spec default() :: preferences()
  def default do
    %{
      voice_key: :disappointed_narrator,
      custom_warmth: nil,
      custom_sharpness: nil,
      custom_humor: nil,
      custom_challenge: nil,
      custom_support: nil,
      updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Update voice selection.
  """
  @spec set_voice(preferences(), atom()) :: preferences()
  def set_voice(prefs, voice_key) when is_map(prefs) do
    %{
      prefs
      | voice_key: voice_key,
        custom_warmth: nil,
        custom_sharpness: nil,
        custom_humor: nil,
        custom_challenge: nil,
        custom_support: nil,
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Customize voice parameters (warmth, sharpness, etc).
  """
  @spec customize_voice(preferences(), map()) :: preferences()
  def customize_voice(prefs, customizations) when is_map(prefs) and is_map(customizations) do
    %{
      prefs
      | voice_key: :custom,
        custom_warmth: Map.get(customizations, "warmth", prefs.custom_warmth),
        custom_sharpness: Map.get(customizations, "sharpness", prefs.custom_sharpness),
        custom_humor: Map.get(customizations, "humor", prefs.custom_humor),
        custom_challenge: Map.get(customizations, "challenge", prefs.custom_challenge),
        custom_support: Map.get(customizations, "support", prefs.custom_support),
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Get effective voice for this user.

  Returns voice preset with customizations applied if custom.
  """
  @spec get_effective_voice(preferences()) :: map()
  def get_effective_voice(prefs) when is_map(prefs) do
    base_voice = VoicePreset.get_preset(prefs.voice_key)

    case prefs.voice_key do
      :custom ->
        %{
          base_voice
          | warmth: prefs.custom_warmth || base_voice.warmth,
            sharpness: prefs.custom_sharpness || base_voice.sharpness,
            humor: prefs.custom_humor || base_voice.humor,
            challenge: prefs.custom_challenge || base_voice.challenge,
            support: prefs.custom_support || base_voice.support
        }

      _ ->
        base_voice
    end
  end

  @doc """
  Encode preferences for storage.
  """
  @spec encode(preferences()) :: String.t()
  def encode(prefs) when is_map(prefs) do
    Jason.encode!(prefs)
  end

  @doc """
  Decode preferences from storage.
  """
  @spec decode(String.t()) :: {:ok, preferences()} | :error
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        voice_key_str = decoded["voice_key"] || "disappointed_narrator"
        voice_key_atom = String.to_atom(voice_key_str)

        {
          :ok,
          %{
            voice_key: voice_key_atom,
            custom_warmth: decoded["custom_warmth"],
            custom_sharpness: decoded["custom_sharpness"],
            custom_humor: decoded["custom_humor"],
            custom_challenge: decoded["custom_challenge"],
            custom_support: decoded["custom_support"],
            updated_at: decoded["updated_at"] || DateTime.utc_now()
          }
        }

      {:error, _} ->
        :error
    end
  end
end
