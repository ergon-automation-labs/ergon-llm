defmodule BotArmyLlm.Services.CreationCanvas do
  @moduledoc """
  Canvas for creative/building tasks.

  Tracks the transformation from raw materials to finished work.
  The maker is present, tending their creation.
  """

  @type stage :: :concept | :prototype | :refinement | :polish | :complete

  @doc """
  Extract creation metadata from task.

  Identifies what's being made, materials, timeline.
  """
  @spec canvas_from_task(map()) :: map()
  def canvas_from_task(task) do
    title = task["title"] || "Untitled Creation"
    description = task["description"] || ""
    duration = task["estimated_duration_minutes"] || 60

    creation_type = identify_creation_type(title, description)
    materials = extract_materials(description)
    stage = estimate_stage(duration, creation_type)

    %{
      "title" => title,
      "type" => creation_type,
      "materials" => materials,
      "stage" => stage,
      "stage_phrase" => stage_phrase(stage),
      "duration_minutes" => duration,
      "is_long_term" => duration > 120
    }
  end

  @doc """
  Get stage description phrase.

  Each stage has its own narrative.
  """
  @spec stage_phrase(stage()) :: String.t()
  def stage_phrase(stage) do
    case stage do
      :concept ->
        "The blank canvas. Everything is possible. Imagination takes shape."

      :prototype ->
        "Raw materials become form. The thing emerges. You're building something real."

      :refinement ->
        "The rough edges become clear. This is where craft matters. You're shaping it."

      :polish ->
        "The vision becomes visible. Details accumulate. Beauty emerges from care."

      :complete ->
        "The thing is done. You made this. It exists because you built it."
    end
  end

  @doc """
  Get maker observation based on creation state.

  The maker's presence, tending their work.
  """
  @spec maker_presence(map()) :: String.t()
  def maker_presence(canvas) when is_map(canvas) do
    stage = canvas["stage"] || :concept
    creation_type = canvas["type"] || "creation"

    case {creation_type, stage} do
      {_, :concept} ->
        "The maker watches the blank space. Possibility hangs in the air."

      {_, :prototype} ->
        "The maker's hands shape raw material. The thing takes form."

      {:code, :refinement} ->
        "Fingers on keys. Logic flows. You're sculpting meaning from syntax."

      {:design, :refinement} ->
        "Eyes on the canvas. Colors, shapes, space. You're tending the balance."

      {:writing, :refinement} ->
        "Words flow. Sentences become paragraphs. You're building a world."

      {_, :refinement} ->
        "The maker refines. Unnecessary falls away. What remains becomes clear."

      {_, :polish} ->
        "The maker polishes. This is love of craft. Every detail matters."

      {:code, :complete} ->
        "The system runs. Code became function. You built something that works."

      {:design, :complete} ->
        "The design stands complete. Beauty and function merged. You made this."

      {:writing, :complete} ->
        "The words are done. A world exists that didn't before. You created it."

      {_, :complete} ->
        "The thing is finished. The maker steps back. What you've built is real."
    end
  end

  @doc """
  Get celebration for creation completion.

  Celebrates the act of making, not just finishing.
  """
  @spec creation_celebration(map()) :: String.t()
  def creation_celebration(canvas) when is_map(canvas) do
    creation_type = canvas["type"] || "creation"

    case creation_type do
      :code ->
        "You wrote code that works. You built a system. That is mastery."

      :design ->
        "You made something beautiful. You shaped space and form. That is art."

      :writing ->
        "You wrote words that mean something. You created a world. That is power."

      :craft ->
        "You made something with your hands. Something useful, something real."

      :music ->
        "You composed sound. You created emotion. That is magic."

      :video ->
        "You shaped motion and image. You created experience. That is vision."

      _ ->
        "You made this. It didn't exist before. Now it does. That is creation."
    end
  end

  @doc """
  Identify what kind of creation is being made.

  Code, design, writing, craft, music, video, etc.
  """
  @spec identify_creation_type(String.t(), String.t()) :: atom()
  def identify_creation_type(title, description) do
    text = "#{title} #{description}" |> String.downcase()

    cond do
      String.contains?(text, ["code", "function", "script", "app", "program"]) ->
        :code

      String.contains?(text, ["design", "ui", "ux", "layout", "graphic"]) ->
        :design

      String.contains?(text, ["write", "essay", "story", "novel", "article", "blog"]) ->
        :writing

      String.contains?(text, ["music", "song", "compose", "beat", "track"]) ->
        :music

      String.contains?(text, ["video", "film", "edit", "motion"]) ->
        :video

      String.contains?(text, ["craft", "build", "make", "construct", "create"]) ->
        :craft

      true ->
        :creation
    end
  end

  @doc """
  Estimate current stage based on duration and type.

  Longer tasks progress through more stages.
  """
  @spec estimate_stage(integer(), atom()) :: stage()
  def estimate_stage(duration_minutes, _type) do
    cond do
      duration_minutes < 15 -> :concept
      duration_minutes < 30 -> :prototype
      duration_minutes < 60 -> :refinement
      duration_minutes < 120 -> :polish
      true -> :complete
    end
  end

  @doc """
  Extract materials/components from task description.

  What raw materials go into this creation?
  """
  @spec extract_materials(String.t()) :: [String.t()]
  def extract_materials(description) do
    materials = [
      "canvas",
      "wood",
      "metal",
      "clay",
      "stone",
      "fabric",
      "paper",
      "paint",
      "ink",
      "code",
      "data",
      "sound",
      "image",
      "word",
      "idea",
      "time",
      "skill"
    ]

    text = description |> String.downcase()

    materials
    |> Enum.filter(&String.contains?(text, &1))
    |> case do
      [] -> ["imagination", "skill", "time"]
      found -> found
    end
  end

  @doc """
  Get progress indicator text.

  Shows journey through stages.
  """
  @spec progress_journey(stage()) :: String.t()
  def progress_journey(stage) do
    stages = [:concept, :prototype, :refinement, :polish, :complete]
    index = Enum.find_index(stages, &(&1 == stage))

    case index do
      nil -> "Beginning..."
      i -> "#{i + 1}/5 stages of creation"
    end
  end
end
