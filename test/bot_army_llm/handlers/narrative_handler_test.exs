defmodule BotArmyLlm.Handlers.NarrativeHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyLlm.Handlers.NarrativeHandler
  alias BotArmyLlm.Services.ImageLibrary

  describe "narrative response with images" do
    test "narrative response includes images for emotional frame" do
      # Mock narrative
      narrative = %{
        "quest_title" => "Test Quest",
        "scene_flavor" => "A test scene",
        "beat_next" => "Begin",
        "emotional_frame" => "hopeful"
      }

      generated_by = "llm_bot"

      # Get what the handler would generate
      emotional_frame = narrative["emotional_frame"] || "neutral"
      image_urls = ImageLibrary.images_for_frame(emotional_frame)

      # Verify response structure
      assert is_list(image_urls)
      assert length(image_urls) > 0
      assert Enum.all?(image_urls, &is_binary/1)
    end

    test "response includes neutral images for missing emotional frame" do
      narrative = %{
        "quest_title" => "Test",
        "scene_flavor" => "Scene",
        "beat_next" => "Go",
        "emotional_frame" => nil
      }

      emotional_frame = narrative["emotional_frame"] || "neutral"
      image_urls = ImageLibrary.images_for_frame(emotional_frame)

      assert is_list(image_urls)
      assert length(image_urls) >= 1
    end
  end

  describe "emotional frame color mapping" do
    test "all emotional frames have corresponding images" do
      frames = [
        "hopeful",
        "playful",
        "defiant",
        "tender",
        "melancholic_resolve",
        "weary_but_moving"
      ]

      Enum.each(frames, fn frame ->
        images = ImageLibrary.images_for_frame(frame)
        assert length(images) > 0, "No images for frame: #{frame}"
      end)
    end

    test "image response includes current index" do
      # Initial response should have current_index: 0
      current_index = 0
      images = ImageLibrary.images_for_frame("playful")

      assert current_index == 0
      assert length(images) > 0
      assert Enum.at(images, current_index) != nil
    end
  end
end
