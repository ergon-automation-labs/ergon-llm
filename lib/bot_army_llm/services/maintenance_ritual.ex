defmodule BotArmyLlm.Services.MaintenanceRitual do
  @moduledoc """
  Ritual timer for maintenance-type quests.

  Frames maintenance tasks as daily rituals: eating, meds, movement, care.
  Provides structured time and celebrates the rhythm of showing up.

  ## Timer States
  - :ready — Ritual ready to begin
  - :in_progress — Ritual underway (elapsed seconds tracked)
  - :complete — Ritual finished (celebration earned)
  """

  @type ritual_state :: :ready | :in_progress | :complete

  @doc """
  Get ritual metadata for a maintenance task.

  Returns:
  - :estimated_minutes — expected duration
  - :ritual_type — category (eat, move, med, care, clean)
  - :ritual_phrase — framing phrase
  """
  @spec ritual_for_task(map()) :: map()
  def ritual_for_task(task) do
    title = task["title"] || ""
    description = task["description"] || ""
    duration = task["estimated_duration_minutes"] || 15

    text = "#{title} #{description}" |> String.downcase()

    ritual_type =
      cond do
        String.contains?(text, ["eat", "food", "meal", "drink", "hydrate"]) -> "eat"
        String.contains?(text, ["med", "meds", "medication", "pill", "vitamin"]) -> "med"
        String.contains?(text, ["move", "walk", "exercise", "stretch", "run"]) -> "move"
        String.contains?(text, ["care", "shower", "bath", "groom", "sleep"]) -> "care"
        String.contains?(text, ["clean", "tidy", "organize", "wash", "dishes"]) -> "clean"
        true -> "ritual"
      end

    ritual_phrase = phrase_for_type(ritual_type)

    %{
      "estimated_minutes" => duration,
      "ritual_type" => ritual_type,
      "ritual_phrase" => ritual_phrase,
      "state" => "ready"
    }
  end

  @doc """
  Get the ritual phrase for a maintenance type.

  Each ritual has a grounding phrase that frames it as necessary.
  """
  @spec phrase_for_type(String.t()) :: String.t()
  def phrase_for_type(type) do
    case type do
      "eat" -> "Nourishment. The body asks. You answer."
      "med" -> "Medicine. Small thing, steady thing. It matters."
      "move" -> "Motion. Blood flowing. Breath moving. You are here."
      "care" -> "Care for yourself like you'd care for someone you love."
      "clean" -> "Order from chaos. The space you hold. Tend it."
      _ -> "The ritual. Simple. Necessary. Eternal."
    end
  end

  @doc """
  Calculate ritual progress from elapsed time.

  Returns:
  - :elapsed_seconds — actual time spent
  - :progress_percent — 0-100 based on estimated duration
  - :time_remaining — seconds left (or :complete)
  """
  @spec calculate_progress(integer(), integer()) :: map()
  def calculate_progress(estimated_minutes, elapsed_seconds) do
    estimated_seconds = estimated_minutes * 60
    progress_percent = min(100, div(elapsed_seconds * 100, estimated_seconds))

    time_remaining =
      case estimated_seconds - elapsed_seconds do
        remaining when remaining > 0 -> remaining
        _ -> :complete
      end

    %{
      "elapsed_seconds" => elapsed_seconds,
      "progress_percent" => progress_percent,
      "time_remaining" => time_remaining,
      "estimated_seconds" => estimated_seconds
    }
  end

  @doc """
  Format seconds for display.

  Returns human-readable "Xm Ys" format.
  """
  @spec format_time(integer() | :complete) :: String.t()
  def format_time(:complete), do: "Complete"

  def format_time(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)

    cond do
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  @doc """
  Get celebration message for ritual completion.

  Frames completion as having shown up, not as having conquered.
  """
  @spec celebration_for_ritual(String.t()) :: String.t()
  def celebration_for_ritual(ritual_type) do
    case ritual_type do
      "eat" -> "Fed. The body is tended. You showed up for yourself."
      "med" -> "Medicine taken. Small thing, steady thing. You are steady."
      "move" -> "Moved. Blood flows. You are here, present, alive."
      "care" -> "You cared for yourself. That is everything."
      "clean" -> "Space tended. The small order you make matters."
      _ -> "The ritual is done. You kept the light on."
    end
  end

  @doc """
  Check if ritual is overdue (elapsed > estimated + 50% grace).

  Used for gentle reminder that the ritual took longer, that's okay.
  """
  @spec is_overdue?(integer(), integer()) :: boolean()
  def is_overdue?(estimated_minutes, elapsed_seconds) do
    estimated_seconds = estimated_minutes * 60
    grace_seconds = div(estimated_seconds, 2)
    elapsed_seconds > estimated_seconds + grace_seconds
  end
end
