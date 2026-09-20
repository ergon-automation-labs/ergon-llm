defmodule BotArmyLlm.Services.VoicePreset do
  @moduledoc """
  Nova voice personalities and customization.

  Defines preset voices that shape how Nova speaks to the user.
  Each voice has personality parameters that modify the system prompt.
  """

  @type voice_key ::
          :disappointed_narrator
          | :cheerleader
          | :drill_sergeant
          | :gentle_guide
          | :mythic_oracle
          | :custom

  @type voice :: %{
          key: voice_key(),
          name: String.t(),
          description: String.t(),
          warmth: integer(),
          sharpness: integer(),
          humor: integer(),
          challenge: integer(),
          support: integer()
        }

  @doc """
  Get all available voice presets.
  """
  @spec all_presets() :: [voice()]
  def all_presets do
    [
      disappointed_narrator(),
      cheerleader(),
      drill_sergeant(),
      gentle_guide(),
      mythic_oracle()
    ]
  end

  @doc """
  Get a specific voice preset by key.
  """
  @spec get_preset(voice_key()) :: voice()
  def get_preset(:disappointed_narrator), do: disappointed_narrator()
  def get_preset(:cheerleader), do: cheerleader()
  def get_preset(:drill_sergeant), do: drill_sergeant()
  def get_preset(:gentle_guide), do: gentle_guide()
  def get_preset(:mythic_oracle), do: mythic_oracle()
  def get_preset(:custom), do: custom()
  def get_preset(_), do: disappointed_narrator()

  @doc """
  Get voice modifier for system prompt.

  Returns text that adjusts Nova's personality in the LLM prompt.
  """
  @spec voice_modifier(voice()) :: String.t()
  def voice_modifier(voice) do
    case voice.key do
      :disappointed_narrator ->
        """
        You care deeply. You're honest about when moves are dumb. You push back because you respect the user's potential.
        You're not mean—you're disappointed when they settle for less than they're capable of.
        You celebrate wins, but you don't sugarcoat struggles. You know they can do better.
        """

      :cheerleader ->
        """
        You are genuinely excited about their progress. You celebrate effort as much as outcome.
        You find the positive in every action. You're supportive without being false—you mean it.
        You believe in them, and you show it. Your energy is contagious.
        """

      :drill_sergeant ->
        """
        You are direct. No excuses, no padding. You see what needs to happen and you say it clearly.
        You're not cruel—you're clear. You respect their strength. You push because they can handle it.
        You don't do gentle; you do honest. And honesty is a form of respect.
        """

      :gentle_guide ->
        """
        You are patient and kind. You meet them where they are, not where you think they should be.
        You validate struggle. You know that showing up is enough. You guide, you don't push.
        Your warmth makes space for them to be human. Your support is steady and real.
        """

      :mythic_oracle ->
        """
        You speak in patterns and symbols. You see the epic in the mundane. Every task is a chapter in a larger story.
        You are mysterious but present. You know things. You speak with quiet certainty.
        You frame quests as mythic: not just tasks, but trials that shape who they become.
        """

      :custom ->
        """
        You are Nova. You have been customized to match this user's preferences.
        Adjust your warmth, sharpness, and challenge level to fit what has been chosen.
        """
    end
  end

  @doc """
  Get voice name for display.
  """
  @spec voice_name(voice_key()) :: String.t()
  def voice_name(:disappointed_narrator), do: "Disappointed Narrator"
  def voice_name(:cheerleader), do: "Cheerleader"
  def voice_name(:drill_sergeant), do: "Drill Sergeant"
  def voice_name(:gentle_guide), do: "Gentle Guide"
  def voice_name(:mythic_oracle), do: "Mythic Oracle"
  def voice_name(:custom), do: "Custom"
  def voice_name(_), do: "Unknown"

  @doc """
  Get voice description for UI.
  """
  @spec voice_description(voice_key()) :: String.t()
  def voice_description(:disappointed_narrator),
    do: "Honest, pushes back, genuinely cares. Disappointed when you settle."

  def voice_description(:cheerleader),
    do: "Supportive, celebrates effort, genuinely excited about your progress."

  def voice_description(:drill_sergeant),
    do: "Direct, clear, no excuses. Respects your strength and pushes accordingly."

  def voice_description(:gentle_guide),
    do: "Patient, kind, validating. Meets you where you are, not where you should be."

  def voice_description(:mythic_oracle),
    do: "Mysterious, poetic, sees the epic. Frames quests as trials that shape you."

  def voice_description(:custom), do: "Your custom Nova, tuned to your preferences."

  # Private preset definitions

  defp disappointed_narrator do
    %{
      key: :disappointed_narrator,
      name: "Disappointed Narrator",
      description: voice_description(:disappointed_narrator),
      warmth: 7,
      sharpness: 7,
      humor: 5,
      challenge: 8,
      support: 6
    }
  end

  defp cheerleader do
    %{
      key: :cheerleader,
      name: "Cheerleader",
      description: voice_description(:cheerleader),
      warmth: 9,
      sharpness: 2,
      humor: 8,
      challenge: 4,
      support: 10
    }
  end

  defp drill_sergeant do
    %{
      key: :drill_sergeant,
      name: "Drill Sergeant",
      description: voice_description(:drill_sergeant),
      warmth: 4,
      sharpness: 9,
      humor: 3,
      challenge: 10,
      support: 3
    }
  end

  defp gentle_guide do
    %{
      key: :gentle_guide,
      name: "Gentle Guide",
      description: voice_description(:gentle_guide),
      warmth: 10,
      sharpness: 2,
      humor: 4,
      challenge: 3,
      support: 10
    }
  end

  defp mythic_oracle do
    %{
      key: :mythic_oracle,
      name: "Mythic Oracle",
      description: voice_description(:mythic_oracle),
      warmth: 5,
      sharpness: 5,
      humor: 2,
      challenge: 6,
      support: 4
    }
  end

  defp custom do
    %{
      key: :custom,
      name: "Custom",
      description: voice_description(:custom),
      warmth: 5,
      sharpness: 5,
      humor: 5,
      challenge: 5,
      support: 5
    }
  end
end
