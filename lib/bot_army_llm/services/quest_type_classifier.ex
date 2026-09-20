defmodule BotArmyLlm.Services.QuestTypeClassifier do
  @moduledoc """
  Classify tasks into quest types based on characteristics.

  Quest types:
  - combat: High intensity, clear goal, immediate feedback (bugs, reports, decisions)
  - reflection: Low intensity, introspective, no failure (journaling, review, processing)
  - maintenance: Routine, sustaining, unglamorous (eat, shower, meds, cleaning)
  - exploration: Discovery, learning, uncertain outcome (read, research, experiment)
  - collaboration: Social, requires others, shared stakes (meetings, group work, ask for help)
  - creation: Making something, expressing, open-ended (write, draw, compose, design)
  """

  @type quest_type ::
          :combat | :reflection | :maintenance | :exploration | :collaboration | :creation

  @doc """
  Classify a task into a quest type based on its metadata.

  Uses task title, description, tags, and estimated duration as signals.
  Falls back to :combat (most common for GTD tasks).
  """
  @spec classify(String.t(), String.t() | nil, list(String.t()), integer() | nil) :: quest_type
  def classify(title, description \\ nil, tags \\ [], estimated_duration_minutes \\ nil) do
    text = "#{title} #{description || ""}" |> String.downcase()

    cond do
      # Explicit tags take precedence
      has_tag?(tags, "reflection") -> :reflection
      has_tag?(tags, "maintenance") or has_tag?(tags, "self-care") -> :maintenance
      has_tag?(tags, "creative") or has_tag?(tags, "creation") -> :creation
      has_tag?(tags, "learning") or has_tag?(tags, "exploration") -> :exploration
      has_tag?(tags, "social") or has_tag?(tags, "collaboration") -> :collaboration
      # Then keyword matching
      matches_reflection?(text, tags) -> :reflection
      matches_maintenance?(text, tags) -> :maintenance
      matches_creation?(text, tags) -> :creation
      matches_exploration?(text, tags) -> :exploration
      matches_collaboration?(text, tags) -> :collaboration
      true -> :combat
    end
  end

  @doc """
  Get metadata for a quest type (narrative style, mechanic, emoji).
  """
  @spec metadata(quest_type) :: map()
  def metadata(quest_type) do
    %{
      combat: %{
        mechanic: "boss_fight",
        emoji: "⚔️",
        color: "#ef4444",
        description: "Battle against a foe"
      },
      reflection: %{
        mechanic: "dialogue",
        emoji: "🪞",
        color: "#8b5cf6",
        description: "Moment of introspection"
      },
      maintenance: %{
        mechanic: "ritual",
        emoji: "🔥",
        color: "#f59e0b",
        description: "Daily devotion"
      },
      exploration: %{
        mechanic: "discovery",
        emoji: "🗺️",
        color: "#06b6d4",
        description: "Journey of discovery"
      },
      collaboration: %{
        mechanic: "alliance",
        emoji: "🤝",
        color: "#10b981",
        description: "Bringing allies together"
      },
      creation: %{
        mechanic: "forge",
        emoji: "🔨",
        color: "#f97316",
        description: "Crafting something new"
      }
    }
    |> Map.get(quest_type, %{})
  end

  # Private classification helpers

  defp matches_reflection?(text, tags) do
    reflection_keywords = [
      "journal",
      "reflect",
      "review",
      "process",
      "think",
      "meditate",
      "contemplate",
      "introspect",
      "feelings",
      "processing",
      "debrief"
    ]

    has_tag?(tags, "reflection") or
      Enum.any?(reflection_keywords, &String.contains?(text, &1))
  end

  defp matches_maintenance?(text, tags) do
    maintenance_keywords = [
      "clean",
      "wash",
      "eat",
      "shower",
      "sleep",
      "meds",
      "medication",
      "exercise",
      "stretch",
      "drink water",
      "break",
      "rest",
      "self-care"
    ]

    has_tag?(tags, "maintenance") or has_tag?(tags, "self-care") or
      Enum.any?(maintenance_keywords, &String.contains?(text, &1))
  end

  defp matches_exploration?(text, tags) do
    exploration_keywords = [
      "read",
      "research",
      "learn",
      "explore",
      "investigate",
      "discover",
      "experiment",
      "try",
      "understand",
      "study",
      "tutorial",
      "course"
    ]

    has_tag?(tags, "learning") or has_tag?(tags, "exploration") or
      Enum.any?(exploration_keywords, &String.contains?(text, &1))
  end

  defp matches_collaboration?(text, tags) do
    collaboration_keywords = [
      "meeting",
      "call",
      "sync",
      "discuss",
      "collaborate",
      "team",
      "ask",
      "help",
      "pair",
      "brainstorm",
      "feedback",
      "review with",
      "talk to",
      "email"
    ]

    has_tag?(tags, "social") or has_tag?(tags, "collaboration") or
      Enum.any?(collaboration_keywords, &String.contains?(text, &1))
  end

  defp matches_creation?(text, tags) do
    creation_keywords = [
      "write",
      "draw",
      "compose",
      "design",
      "create",
      "build",
      "code",
      "paint",
      "make",
      "craft",
      "edit",
      "produce",
      "publish",
      "design"
    ]

    has_tag?(tags, "creative") or has_tag?(tags, "creation") or
      Enum.any?(creation_keywords, &String.contains?(text, &1))
  end

  defp has_tag?(tags, needle) do
    Enum.any?(tags, &String.contains?(String.downcase(&1), String.downcase(needle)))
  end
end
