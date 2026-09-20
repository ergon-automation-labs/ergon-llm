defmodule BotArmyLlm.Services.AllianceSystem do
  @moduledoc """
  Alliance tracking for collaborative quests.

  Identifies collaborators, estimates their strength, calculates combined power.
  Collaboration is about "we", not "you".
  """

  @type ally :: %{
          name: String.t(),
          strength: integer(),
          role: String.t()
        }

  @type alliance :: %{
          allies: [ally()],
          combined_strength: integer(),
          morale: String.t()
        }

  @doc """
  Extract allies from collaboration task context.

  Looks for mentions of people, teams, or entities in task data.
  """
  @spec allies_from_task(map()) :: [ally()]
  def allies_from_task(task) do
    description = task["description"] || ""
    title = task["title"] || ""
    assigned_to = task["assigned_to"] || []
    collaborators = task["collaborators"] || []
    tags = task["tags"] || []

    text = "#{title} #{description}" |> String.downcase()

    # Extract explicit collaborators
    explicit_allies =
      Enum.map(collaborators, fn c ->
        %{
          name: c["name"] || c,
          strength: estimate_strength(c),
          role: identify_role(c)
        }
      end)

    # Extract implicit allies from description
    implicit_allies = extract_allies_from_text(text)

    # Assigned team members
    team_allies =
      Enum.map(assigned_to, fn person ->
        %{
          name: person["name"] || person,
          strength: 5,
          role: "team member"
        }
      end)

    # Combine and deduplicate by name
    (explicit_allies ++ implicit_allies ++ team_allies)
    |> Enum.uniq_by(& &1.name)
    |> Enum.filter(fn ally -> String.length(ally.name) > 0 end)
  end

  @doc """
  Calculate combined alliance strength.

  Returns 1-10 scale based on number and quality of allies.
  """
  @spec combined_strength([ally()]) :: integer()
  def combined_strength(allies) when is_list(allies) do
    case length(allies) do
      0 ->
        1

      1 ->
        Enum.at(allies, 0).strength

      count ->
        total_strength = allies |> Enum.map(& &1.strength) |> Enum.sum()
        min(10, div(total_strength, count) + count - 1)
    end
  end

  @doc """
  Get morale assessment for alliance.

  Returns emotional state of the group based on ally count and strength.
  """
  @spec morale([ally()]) :: String.t()
  def morale(allies) when is_list(allies) do
    strength = combined_strength(allies)
    count = length(allies)

    cond do
      count == 0 -> "solo"
      count == 1 and strength >= 7 -> "strong_ally"
      count == 1 -> "single_companion"
      count >= 3 and strength >= 8 -> "formidable_force"
      count >= 3 -> "united"
      strength >= 8 -> "powerful_team"
      true -> "determined_group"
    end
  end

  @doc """
  Get morale phrase for display.

  Reframes the collaboration state emotionally.
  """
  @spec morale_phrase(String.t()) :: String.t()
  def morale_phrase(morale_state) do
    case morale_state do
      "solo" -> "Standing alone. Your strength is your own."
      "strong_ally" -> "One fierce ally at your side."
      "single_companion" -> "You have someone who believes in this."
      "formidable_force" -> "Together, you are formidable."
      "united" -> "United. That changes everything."
      "powerful_team" -> "A powerful team. The odds shift."
      "determined_group" -> "A determined group. You can do this."
      _ -> "Together, you are stronger."
    end
  end

  @doc """
  Get collaboration prompts based on alliance composition.

  Different questions for solo, duo, team.
  """
  @spec collaboration_prompts([ally()]) :: [String.t()]
  def collaboration_prompts(allies) when is_list(allies) do
    count = length(allies)

    case count do
      0 ->
        [
          "What would help you be less alone in this?",
          "Who could you ask for support?",
          "What strength do you bring by yourself?"
        ]

      1 ->
        [
          "What does your ally bring that you don't have?",
          "How does your ally see you?",
          "What can you do together that you can't alone?"
        ]

      _ ->
        [
          "What does this group do well together?",
          "Who relies on you in this group?",
          "How is the group stronger than its parts?",
          "What can you only do as a team?",
          "Who are you for them?"
        ]
    end
  end

  @doc """
  Format allies for display.

  Returns human-readable ally list.
  """
  @spec format_allies([ally()]) :: String.t()
  def format_allies(allies) when is_list(allies) do
    case allies do
      [] -> "Standing alone"
      [single] -> single.name
      list -> Enum.map_join(list, ", ", & &1.name)
    end
  end

  # Private helpers

  defp estimate_strength(collaborator) when is_map(collaborator) do
    strength = collaborator["strength"] || 5
    max(1, min(10, strength))
  end

  defp estimate_strength(_), do: 5

  defp identify_role(collaborator) when is_map(collaborator) do
    collaborator["role"] || collaborator["type"] || "collaborator"
  end

  defp identify_role(_), do: "collaborator"

  defp extract_allies_from_text(text) do
    # Look for common collaboration phrases
    roles = [
      {"with ", "collaborator"},
      {"team", "team member"},
      {"group", "team member"},
      {"pair", "partner"},
      {"partner", "partner"},
      {"together with", "ally"}
    ]

    Enum.flat_map(roles, fn {phrase, role} ->
      if String.contains?(text, phrase) do
        [
          %{
            name: String.capitalize(role),
            strength: 5,
            role: role
          }
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.role)
  end
end
