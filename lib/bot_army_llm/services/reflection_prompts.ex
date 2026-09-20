defmodule BotArmyLlm.Services.ReflectionPrompts do
  @moduledoc """
  Generate reflection prompts for introspection quests.

  Provides rotating, contextual questions that invite self-reflection.
  Prompts vary based on energy level, streak, and emotional frame.
  """

  @prompts_by_energy %{
    # High energy: forward-looking, ambitious
    high: [
      "What did this reveal about what you're capable of?",
      "What would the next level of this look like?",
      "Who could you share this with?",
      "What did you learn about yourself?",
      "How did this change your thinking?",
      "What's the smallest version of this you could do tomorrow?",
      "What made this feel good?"
    ],
    # Medium energy: balanced, curious
    medium: [
      "What surprised you about this?",
      "What made this hard?",
      "What would you do differently next time?",
      "What did you notice about yourself?",
      "How do you feel about this now?",
      "What's one thing that went well?",
      "What's one thing you'd change?",
      "What do you need to move forward?"
    ],
    # Low energy: gentle, present-focused
    low: [
      "What does your body need right now?",
      "What was one small good thing today?",
      "How are you feeling?",
      "What helped you show up?",
      "What can you let go of?",
      "What's enough for today?",
      "What do you need to rest?"
    ]
  }

  @prompts_by_frame %{
    hopeful: [
      "What's possible next?",
      "What are you becoming?",
      "What would you try if you knew you'd succeed?",
      "Who are you becoming?"
    ],
    playful: [
      "What made you smile?",
      "What was fun about this?",
      "What would make this more playful?",
      "What felt easy?"
    ],
    defiant: [
      "What are you refusing to accept?",
      "What's worth the fight?",
      "How did you push back?",
      "What are you standing for?"
    ],
    tender: [
      "What needs care right now?",
      "What are you protecting?",
      "How did you show up for yourself?",
      "What deserves gentleness?"
    ],
    melancholic_resolve: [
      "What's the weight you're carrying?",
      "What matters even when it's hard?",
      "Why do you keep going?",
      "What are you grieving?"
    ],
    weary_but_moving: [
      "What's one thing that helped?",
      "How did you show up anyway?",
      "What can rest for now?",
      "What's the smallest next step?"
    ]
  }

  @doc """
  Get a reflection prompt for the given context.

  Returns a single prompt based on energy level and emotional frame.
  Uses rotation across multiple calls to vary the experience.
  """
  @spec get_prompt(integer(), String.t()) :: String.t()
  def get_prompt(energy_level \\ 5, emotional_frame \\ "weary_but_moving") do
    # Select prompt bucket by energy
    energy_bucket =
      cond do
        energy_level >= 7 -> :high
        energy_level >= 4 -> :medium
        true -> :low
      end

    energy_prompts = Map.get(@prompts_by_energy, energy_bucket, [])

    # Try to get frame-specific prompt if available
    frame_key = String.to_atom(emotional_frame)
    frame_prompts = Map.get(@prompts_by_frame, frame_key, [])

    # Merge both lists, prefer frame-specific ones
    all_prompts = frame_prompts ++ energy_prompts

    case all_prompts do
      [] -> "What's on your mind?"
      prompts -> Enum.random(prompts)
    end
  end

  @doc """
  Get multiple reflection prompts for display/rotation.

  Returns a list of 3-5 prompts for the UI to rotate through.
  """
  @spec get_prompt_rotation(integer(), String.t(), non_neg_integer()) :: [String.t()]
  def get_prompt_rotation(energy_level \\ 5, emotional_frame \\ "weary_but_moving", count \\ 5) do
    energy_bucket =
      cond do
        energy_level >= 7 -> :high
        energy_level >= 4 -> :medium
        true -> :low
      end

    energy_prompts = Map.get(@prompts_by_energy, energy_bucket, [])
    frame_key = String.to_atom(emotional_frame)
    frame_prompts = Map.get(@prompts_by_frame, frame_key, [])

    all_prompts = frame_prompts ++ energy_prompts

    all_prompts
    |> Enum.uniq()
    |> Enum.take(count)
  end

  @doc """
  Get prompts for a specific emotional frame.
  """
  @spec prompts_for_frame(String.t()) :: [String.t()]
  def prompts_for_frame(emotional_frame) do
    frame_key = String.to_atom(emotional_frame)
    Map.get(@prompts_by_frame, frame_key, ["What's on your mind?"])
  end
end
