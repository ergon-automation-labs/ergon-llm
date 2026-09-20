defmodule BotArmyLlm.Services.SceneFramer do
  @moduledoc """
  Generate scene-setting narrative details based on context.

  Creates immersive scene descriptions that ground the task in a specific
  location and time, making the narrative feel real and present.

  Used to prepend contextual details to task narratives.
  """

  require Logger

  @doc """
  Generate scene-setting preamble for a narrative.

  Returns string with scene details, empty string if location unknown.
  """
  @spec frame_scene(map()) :: String.t()
  def frame_scene(context) when is_map(context) do
    location = context["location"] || :unknown
    time_period = context["time_period"] || :day
    presence = context["presence"] || :alone

    scene_for_location(location, time_period, presence)
  end

  @doc """
  Get location-specific narrative framing.
  """
  @spec location_vibe(atom()) :: String.t()
  def location_vibe(:bathroom) do
    "The bathroom is a sanctuary. Soft light, the gentle sound of water, your own reflection."
  end

  def location_vibe(:kitchen) do
    "The kitchen hums with purpose. Surfaces clear, tools at hand, ingredients waiting."
  end

  def location_vibe(:bedroom) do
    "Your space. Familiar comfort, soft fabrics, the quiet where you can breathe."
  end

  def location_vibe(:gym) do
    "The air is charged. Equipment waits. Your body knows what to do here."
  end

  def location_vibe(:work) do
    "Focus mode. The world narrows to what matters. You know this space."
  end

  def location_vibe(:couch) do
    "Your nest. The world outside fades. Here, you can let go and restore."
  end

  def location_vibe(:unknown) do
    ""
  end

  @doc """
  Get time-of-day specific details.
  """
  @spec time_vibe(atom()) :: String.t()
  def time_vibe(:morning) do
    "Morning light is honest. No filters, no excuses. Just possibility."
  end

  def time_vibe(:afternoon) do
    "The day is in motion. You have momentum. Use it."
  end

  def time_vibe(:evening) do
    "The world slows. Energy shifts from doing to being. Notice what you've earned."
  end

  def time_vibe(:night) do
    "Night is for the brave and the weary. Whatever you do now matters."
  end

  @doc """
  Get presence-based framing.
  """
  @spec presence_vibe(atom()) :: String.t()
  def presence_vibe(:alone) do
    "You're on your own. That's your strength."
  end

  def presence_vibe(:with_partner) do
    "Louiza is here. Or you know she's just a moment away. Not alone."
  end

  def presence_vibe(:group) do
    "You're with your people. You've got this together."
  end

  # Private

  defp scene_for_location(:unknown, _time, _presence) do
    ""
  end

  defp scene_for_location(location, time_period, presence) do
    location_detail = location_vibe(location)
    time_detail = time_vibe(time_period)
    presence_detail = presence_vibe(presence)

    [location_detail, time_detail, presence_detail]
    |> Enum.reject(&(byte_size(&1) == 0))
    |> Enum.join(" ")
    |> then(fn text ->
      if byte_size(text) == 0 do
        ""
      else
        text <> "\n\n"
      end
    end)
  end
end
