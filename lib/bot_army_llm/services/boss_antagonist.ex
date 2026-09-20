defmodule BotArmyLlm.Services.BossAntagonist do
  @moduledoc """
  Boss antagonist that comments on the player's progress.

  The boss grows in power and sharpness as the player faces harder quests.
  Taunts scale with difficulty and track patterns in the player's activity.
  """

  @type difficulty :: 1..10
  @type power_tier :: :mocking | :engaged | :vicious

  @doc """
  Get antagonist power tier based on cumulative difficulty.

  Higher cumulative difficulty = more engaged and sharp antagonist.
  """
  @spec power_tier(integer()) :: power_tier()
  def power_tier(cumulative_difficulty) do
    cond do
      cumulative_difficulty < 20 -> :mocking
      cumulative_difficulty < 50 -> :engaged
      true -> :vicious
    end
  end

  @doc """
  Generate a "meanwhile" taunt about the player's last action.

  Reacts to what quest type they just completed and current energy.
  """
  @spec taunt_for_completion(String.t(), difficulty(), integer(), integer()) :: String.t()
  def taunt_for_completion(quest_type, difficulty, energy_level, cumulative_difficulty) do
    tier = power_tier(cumulative_difficulty)

    taunts =
      case {quest_type, tier} do
        {:combat, :mocking} ->
          [
            "Level-#{difficulty}? You barely scratched that one. Getting brave, are we?",
            "Oh, you took down a level-#{difficulty} enemy? How... ambitious.",
            "Level-#{difficulty} and you're still standing. That was cute."
          ]

        {:combat, :engaged} ->
          [
            "Not bad. Level-#{difficulty}? You're getting interesting.",
            "I'm starting to pay attention. Keep going.",
            "That took you down, didn't it? But you kept moving. Respect."
          ]

        {:combat, :vicious} ->
          [
            "Level-#{difficulty}. You're picking fights now. Good.",
            "I see you. Every scar you earn, I see it.",
            "You're learning. But you're not ready for what's coming."
          ]

        {:reflection, :mocking} ->
          [
            "Oh look, you're thinking about your feelings. How therapeutic.",
            "Navel-gazing? That won't help you.",
            "You stopped fighting long enough to think. Interesting choice."
          ]

        {:reflection, :engaged} ->
          [
            "You're more thoughtful than you look. I'll give you that.",
            "Introspection. You're learning what matters.",
            "You're watching yourself. That's dangerous."
          ]

        {:reflection, :vicious} ->
          [
            "You know yourself now. That makes you stronger... and more fragile.",
            "Self-awareness is a weapon. Don't drop it.",
            "You understand what you're risking. Good."
          ]

        {:maintenance, :mocking} ->
          if energy_level >= 7 do
            [
              "Oh, you took care of yourself. Shocking.",
              "Fed and rested? How responsible of you."
            ]
          else
            [
              "Barely holding it together, I see.",
              "You're running on fumes and hope. That won't last."
            ]
          end

        {:maintenance, :engaged} ->
          [
            "You're keeping the machine running. I respect that.",
            "Self-maintenance. The underrated power.",
            "You understand: survival first, glory later."
          ]

        {:maintenance, :vicious} ->
          [
            "Every scar you don't take is a victory you've earned.",
            "You learned to tend yourself. That's wisdom.",
            "You're stronger because you know when to rest."
          ]

        {:exploration, :mocking} ->
          [
            "Poking around? Trying to find an advantage?",
            "Discovery is for people with time.",
            "What are you looking for out there?"
          ]

        {:exploration, :engaged} ->
          [
            "You're mapping your world. Good instinct.",
            "Finding new territory. Expanding your reach.",
            "The more you see, the more you understand what you're up against."
          ]

        {:exploration, :vicious} ->
          [
            "You're not just surviving anymore. You're *exploring*.",
            "Knowledge is power. And you're gathering both.",
            "Every place you discover is another battlefield."
          ]

        {:collaboration, :mocking} ->
          [
            "Working with others? How... social.",
            "Finding allies? You'll need them."
          ]

        {:collaboration, :engaged} ->
          [
            "You understand: alone, you're limited. Together, you're dangerous.",
            "Building a network. Smart.",
            "Allies make you formidable. I'm beginning to worry."
          ]

        {:collaboration, :vicious} ->
          [
            "Your allies are strong. But are they strong enough?",
            "You've built something. Let's see if it holds.",
            "United against me? I look forward to it."
          ]

        {:creation, :mocking} ->
          [
            "You're making something? How precious.",
            "Creation takes time. Time you might not have.",
            "What are you building?"
          ]

        {:creation, :engaged} ->
          [
            "You're not just surviving. You're *making*.",
            "Creation requires focus and will. You have both.",
            "What you build will determine what you become."
          ]

        {:creation, :vicious} ->
          [
            "Every thing you create is a statement. I'm listening.",
            "You're shaping your world. One day, you'll shape mine.",
            "The maker becomes the master. Eventually."
          ]

        _ ->
          [
            "Meanwhile... you continue. Impressive persistence.",
            "You're still moving. That takes something.",
            "What comes next for you?"
          ]
      end

    Enum.random(taunts)
  end

  @doc """
  Generate anticipatory taunt about the next quest.

  Predicts what's coming and builds tension.
  """
  @spec taunt_for_next_quest(String.t(), difficulty(), integer()) :: String.t()
  def taunt_for_next_quest(next_quest_type, predicted_difficulty, cumulative_difficulty) do
    tier = power_tier(cumulative_difficulty)

    taunts =
      case {next_quest_type, tier} do
        {:combat, :mocking} ->
          [
            "Level-#{predicted_difficulty} is waiting. You ready?",
            "Next up: something that won't be so easy.",
            "I wonder how you'll handle this one."
          ]

        {:combat, :engaged} ->
          [
            "Level-#{predicted_difficulty}. This one has teeth.",
            "Your next opponent respects you. That's why they'll be ruthless.",
            "You're about to meet someone at your level."
          ]

        {:combat, :vicious} ->
          [
            "Level-#{predicted_difficulty}. This is where we find out what you're made of.",
            "The harder they come, the brighter they burn. Are you ready to burn?",
            "Your next opponent will test everything."
          ]

        {:reflection, _} ->
          [
            "Time to look inward again.",
            "Are you ready to see what you've become?",
            "Introspection awaits."
          ]

        {:maintenance, _} ->
          [
            "The small things matter most.",
            "Keep yourself running. You'll need the fuel.",
            "Tend the engine."
          ]

        {:exploration, :mocking} ->
          [
            "More territory to map.",
            "What secrets are out there waiting for you?"
          ]

        {:exploration, :engaged} ->
          [
            "The world is vast. You're beginning to see it.",
            "New ground to cover. New threats to meet."
          ]

        {:exploration, :vicious} ->
          [
            "Every frontier holds danger and opportunity.",
            "You're not afraid to go deeper anymore. Good."
          ]

        {:collaboration, _} ->
          [
            "Time to trust someone else.",
            "See if your allies are worth what you've invested in them.",
            "Together or alone? You're about to find out."
          ]

        {:creation, _} ->
          [
            "What will you build next?",
            "Creation and destruction are closer than you think.",
            "Make something worthy of your struggle."
          ]

        _ ->
          [
            "What's next?",
            "You're still standing. Let's see how far that takes you.",
            "The game continues."
          ]
      end

    Enum.random(taunts)
  end

  @doc """
  Generate pattern-aware taunt about the player's activity.

  Notices if they're avoiding certain quest types or pushing too hard.
  """
  @spec taunt_for_pattern(
          completed_type :: String.t() | nil,
          avoided_type :: String.t() | nil,
          streak_days :: integer(),
          power_level :: integer()
        ) :: String.t()
  def taunt_for_pattern(completed_type, avoided_type, streak_days, power_level) do
    tier = power_tier(power_level)

    cond do
      avoided_type && tier in [:engaged, :vicious] ->
        [
          "Avoiding #{avoided_type}? I notice what you won't face.",
          "You keep choosing the same type. Smart, or scared?",
          "There's something you're not ready for yet."
        ]
        |> Enum.random()

      streak_days > 7 && tier == :vicious ->
        [
          "Seven days straight? You're either committed or desperate.",
          "That streak is building something in you. I can feel it.",
          "Every day you don't break feeds the fire."
        ]
        |> Enum.random()

      streak_days > 14 ->
        [
          "#{streak_days} days? That's not luck anymore. That's will.",
          "This streak... you're becoming something.",
          "Keep this up and you might actually threaten me."
        ]
        |> Enum.random()

      streak_days == 0 ->
        [
          "Streak broken? Welcome back.",
          "Starting over. That takes courage.",
          "The fall just makes the next climb harder."
        ]
        |> Enum.random()

      true ->
        [
          "You're building momentum.",
          "Day by day. That's how empires fall.",
          "I'm watching your pattern. It's becoming clear."
        ]
        |> Enum.random()
    end
  end

  @doc """
  Get a general threatening observation about power level.

  The boss notices the gap closing.
  """
  @spec power_observation(integer(), integer()) :: String.t()
  def power_observation(player_cumulative, boss_cumulative) do
    gap = boss_cumulative - player_cumulative

    cond do
      gap > 100 ->
        "You're so far below me, I'm not sure you can see where I stand."

      gap > 50 ->
        "There's still a vast distance between us. But you're climbing."

      gap > 20 ->
        "The gap is closing. Finally, a worthy opponent emerges."

      gap > 5 ->
        "You're nearly at my level. This will be interesting."

      gap <= 5 ->
        "We're equals now. And that means the real fight begins."

      true ->
        "You've surpassed me? Then we'll see who the real antagonist is."
    end
  end
end
