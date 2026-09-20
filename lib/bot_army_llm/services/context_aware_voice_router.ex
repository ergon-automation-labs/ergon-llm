defmodule BotArmyLlm.Services.ContextAwareVoiceRouter do
  @moduledoc """
  Routes to contextually appropriate voice based on task and emotional state.

  Matches voice to task type and difficulty for optimal emotional scaffolding:
  - Hard accountability tasks → Commanding Authority
  - Self-care/recovery tasks → Nurturing Aftercare
  - Default → User's preferred voice or adaptive recommendation

  Works alongside AdaptivePreferences: routing decides the BEST voice for
  context; adaptive learning personalizes within those constraints.
  """

  require Logger
  alias BotArmyLlm.Services.UserPreferences

  @doc """
  Route to contextually appropriate voice.

  Returns voice_key to use for narrative generation based on quest type,
  difficulty, and emotional context.

  Falls back to user preferences if no contextual override applies.
  """
  @spec route_voice(atom(), integer(), String.t(), UserPreferences.t()) :: atom()
  def route_voice(quest_type, difficulty, emotional_frame, user_prefs) do
    case context_override(quest_type, difficulty, emotional_frame) do
      nil ->
        # No override: use user's adaptive preference
        user_prefs.voice_key

      override_voice ->
        # Override applies: use contextual voice
        Logger.debug(
          "Voice routed to #{override_voice} (quest=#{quest_type}, difficulty=#{difficulty})"
        )

        override_voice
    end
  end

  @doc """
  Check if a context override voice is recommended.

  Returns recommended voice_key or nil if no override applies.
  """
  @spec context_override(atom(), integer(), String.t()) :: atom() | nil
  def context_override(quest_type, difficulty, emotional_frame) do
    cond do
      # Self-care quests always get Nurturing Aftercare
      self_care_quest?(quest_type) ->
        :nurturing_aftercare

      # Hard quests (7+) with challenging emotional frames get Commanding Authority
      hard_accountability_quest?(quest_type, difficulty, emotional_frame) ->
        :commanding_authority

      # Default: no override
      true ->
        nil
    end
  end

  @doc """
  Get routing reason for logging/feedback.
  """
  @spec routing_reason(atom(), atom()) :: String.t()
  def routing_reason(quest_type, voice_key) do
    case {quest_type, voice_key} do
      {_, :nurturing_aftercare} ->
        "Self-care moment: nurturing support"

      {_, :commanding_authority} ->
        "Hard work ahead: steady accountability"

      _ ->
        "Using your preferred voice"
    end
  end

  # Helpers

  defp self_care_quest?(quest_type) do
    quest_type in [:maintenance, :reflection, :creation]
  end

  defp hard_accountability_quest?(quest_type, difficulty, _emotional_frame) do
    difficulty >= 7 && accountability_quest?(quest_type)
  end

  defp accountability_quest?(quest_type) do
    quest_type in [:combat, :exploration]
  end
end
