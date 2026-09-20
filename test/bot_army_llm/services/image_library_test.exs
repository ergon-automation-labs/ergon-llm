defmodule BotArmyLlm.Services.ImageLibraryTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.ImageLibrary

  describe "images_for_frame" do
    test "returns list of images for valid emotional frame" do
      images = ImageLibrary.images_for_frame("hopeful")
      assert is_list(images)
      assert length(images) > 0
    end

    test "returns empty list for unknown frame" do
      images = ImageLibrary.images_for_frame("unknown_frame")
      assert images == []
    end

    test "returns images for all supported frames" do
      frames = [
        "hopeful",
        "playful",
        "defiant",
        "tender",
        "melancholic_resolve",
        "weary_but_moving",
        "neutral"
      ]

      Enum.each(frames, fn frame ->
        images = ImageLibrary.images_for_frame(frame)
        assert is_list(images), "No images for frame: #{frame}"
        assert length(images) > 0, "Empty image list for frame: #{frame}"
      end)
    end
  end

  describe "get_image" do
    test "returns image at valid index" do
      image = ImageLibrary.get_image("hopeful", 0)
      assert is_binary(image)
      assert String.contains?(image, "/images/hopeful/")
    end

    test "returns nil for out-of-bounds index" do
      image = ImageLibrary.get_image("hopeful", 999)
      assert is_nil(image)
    end

    test "returns nil for unknown frame" do
      image = ImageLibrary.get_image("unknown", 0)
      assert is_nil(image)
    end
  end

  describe "next_index" do
    test "increments index within bounds" do
      next_idx = ImageLibrary.next_index("hopeful", 0)
      assert next_idx == 1
    end

    test "wraps around to 0 when at end" do
      # Get count first
      images = ImageLibrary.images_for_frame("hopeful")
      last_idx = length(images) - 1

      next_idx = ImageLibrary.next_index("hopeful", last_idx)
      assert next_idx == 0
    end

    test "returns 0 for unknown frame" do
      next_idx = ImageLibrary.next_index("unknown_frame", 0)
      assert next_idx == 0
    end

    test "cycles correctly through all images" do
      images = ImageLibrary.images_for_frame("playful")
      count = length(images)

      # Cycle through all images
      indices =
        Enum.reduce(0..(count + 2), [0], fn _, acc ->
          next = ImageLibrary.next_index("playful", List.last(acc))
          acc ++ [next]
        end)

      # Should see: 0, 1, 2, ..., count-1, 0, 1, 0
      assert List.last(indices) == 0
    end
  end
end
