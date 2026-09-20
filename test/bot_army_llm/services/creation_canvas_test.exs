defmodule BotArmyLlm.Services.CreationCanvasTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.CreationCanvas

  describe "canvas_from_task/1" do
    test "extracts creation metadata from task" do
      task = %{
        "title" => "Write a blog post",
        "description" => "About design principles",
        "estimated_duration_minutes" => 45
      }

      canvas = CreationCanvas.canvas_from_task(task)
      assert canvas["title"] == "Write a blog post"
      assert canvas["duration_minutes"] == 45
      assert is_atom(canvas["stage"])
    end

    test "identifies writing creation type" do
      task = %{
        "title" => "Write essay",
        "description" => "On technology",
        "estimated_duration_minutes" => 60
      }

      canvas = CreationCanvas.canvas_from_task(task)
      assert canvas["type"] == :writing
    end

    test "identifies code creation type" do
      task = %{
        "title" => "Build function",
        "description" => "Implement algorithm",
        "estimated_duration_minutes" => 90
      }

      canvas = CreationCanvas.canvas_from_task(task)
      assert canvas["type"] == :code
    end

    test "identifies design creation type" do
      task = %{
        "title" => "Design UI",
        "description" => "Create layout",
        "estimated_duration_minutes" => 120
      }

      canvas = CreationCanvas.canvas_from_task(task)
      assert canvas["type"] == :design
    end
  end

  describe "stage_phrase/1" do
    test "returns phrase for each stage" do
      stages = [:concept, :prototype, :refinement, :polish, :complete]

      Enum.each(stages, fn stage ->
        phrase = CreationCanvas.stage_phrase(stage)
        assert is_binary(phrase)
        assert String.length(phrase) > 0
      end)
    end
  end

  describe "maker_presence/1" do
    test "returns presence for concept stage" do
      canvas = %{"stage" => :concept, "type" => :code}
      presence = CreationCanvas.maker_presence(canvas)
      assert String.contains?(presence, "blank") or String.contains?(presence, "maker")
    end

    test "returns presence for complete stage" do
      canvas = %{"stage" => :complete, "type" => :design}
      presence = CreationCanvas.maker_presence(canvas)
      assert String.contains?(presence, "complete") or String.contains?(presence, "finished")
    end

    test "varies by creation type" do
      code_canvas = %{"stage" => :refinement, "type" => :code}
      write_canvas = %{"stage" => :refinement, "type" => :writing}

      code_presence = CreationCanvas.maker_presence(code_canvas)
      write_presence = CreationCanvas.maker_presence(write_canvas)

      assert is_binary(code_presence)
      assert is_binary(write_presence)
    end
  end

  describe "creation_celebration/1" do
    test "returns celebration for code" do
      canvas = %{"type" => :code}
      celebration = CreationCanvas.creation_celebration(canvas)
      assert String.contains?(celebration, "code") or String.contains?(celebration, "built")
    end

    test "returns celebration for writing" do
      canvas = %{"type" => :writing}
      celebration = CreationCanvas.creation_celebration(canvas)
      assert String.contains?(celebration, "words") or String.contains?(celebration, "world")
    end

    test "returns celebration for design" do
      canvas = %{"type" => :design}
      celebration = CreationCanvas.creation_celebration(canvas)
      assert String.contains?(celebration, "beautiful") or String.contains?(celebration, "art")
    end
  end

  describe "identify_creation_type/2" do
    test "identifies all creation types" do
      assert CreationCanvas.identify_creation_type("Write code", "function") == :code
      assert CreationCanvas.identify_creation_type("Design UI", "layout") == :design
      assert CreationCanvas.identify_creation_type("Write essay", "article") == :writing
      assert CreationCanvas.identify_creation_type("Make music", "compose") == :music
      assert CreationCanvas.identify_creation_type("Create video", "edit") == :video
    end

    test "defaults to creation when type unclear" do
      type = CreationCanvas.identify_creation_type("Do something", "vague task")
      assert type == :creation
    end
  end

  describe "extract_materials/1" do
    test "finds materials in description" do
      description = "Paint on canvas with ink"
      materials = CreationCanvas.extract_materials(description)
      assert "paint" in materials
      assert "canvas" in materials
      assert "ink" in materials
    end

    test "returns defaults when no materials found" do
      description = "Generic task"
      materials = CreationCanvas.extract_materials(description)
      assert length(materials) > 0
      assert "imagination" in materials or "skill" in materials
    end

    test "extracts code materials" do
      description = "Write code and data structures"
      materials = CreationCanvas.extract_materials(description)
      assert "code" in materials or "data" in materials
    end
  end

  describe "estimate_stage/2" do
    test "concept for very short tasks" do
      stage = CreationCanvas.estimate_stage(10, :code)
      assert stage == :concept
    end

    test "prototype for short tasks" do
      stage = CreationCanvas.estimate_stage(20, :code)
      assert stage == :prototype
    end

    test "refinement for medium tasks" do
      stage = CreationCanvas.estimate_stage(45, :code)
      assert stage == :refinement
    end

    test "polish for longer tasks" do
      stage = CreationCanvas.estimate_stage(90, :code)
      assert stage == :polish
    end

    test "complete for very long tasks" do
      stage = CreationCanvas.estimate_stage(240, :code)
      assert stage == :complete
    end
  end

  describe "progress_journey/1" do
    test "returns progress string for each stage" do
      stages = [:concept, :prototype, :refinement, :polish, :complete]

      Enum.each(stages, fn stage ->
        journey = CreationCanvas.progress_journey(stage)
        assert is_binary(journey)
        assert String.length(journey) > 0
      end)
    end
  end
end
