defmodule BotArmyLlm.Services.ImageLibrary do
  @moduledoc """
  Image library for Nova narrative scenes.

  Maps emotional frames to sets of image URLs for visual variety.
  Images rotate on successive scene rewrites to reduce bandwidth/tokens.
  """

  @doc """
  Get all images for an emotional frame.

  Returns list of image URLs or empty list if frame not found.
  """
  def images_for_frame(emotional_frame) do
    library() |> Map.get(emotional_frame, [])
  end

  @doc """
  Get image at specific index for a frame.

  Returns URL or nil if index out of bounds.
  """
  def get_image(emotional_frame, index) do
    images = images_for_frame(emotional_frame)
    Enum.at(images, index)
  end

  @doc """
  Get next image index (wraps around).
  """
  def next_index(emotional_frame, current_index) do
    images = images_for_frame(emotional_frame)
    count = length(images)

    if count == 0, do: 0, else: rem(current_index + 1, count)
  end

  @doc """
  Image library by emotional frame.

  Placeholder URLs - replace with actual asset paths or URLs.
  """
  defp library do
    %{
      "hopeful" => [
        "/images/hopeful/dawn.jpg",
        "/images/hopeful/sunrise.jpg",
        "/images/hopeful/light.jpg"
      ],
      "playful" => [
        "/images/playful/joy.jpg",
        "/images/playful/color.jpg",
        "/images/playful/whimsy.jpg"
      ],
      "defiant" => [
        "/images/defiant/resolve.jpg",
        "/images/defiant/strength.jpg",
        "/images/defiant/fire.jpg"
      ],
      "tender" => [
        "/images/tender/gentle.jpg",
        "/images/tender/care.jpg",
        "/images/tender/warmth.jpg"
      ],
      "melancholic_resolve" => [
        "/images/melancholic/rain.jpg",
        "/images/melancholic/reflection.jpg",
        "/images/melancholic/quiet.jpg"
      ],
      "weary_but_moving" => [
        "/images/weary/path.jpg",
        "/images/weary/perseverance.jpg",
        "/images/weary/journey.jpg"
      ],
      "neutral" => [
        "/images/neutral/calm.jpg"
      ]
    }
  end
end
