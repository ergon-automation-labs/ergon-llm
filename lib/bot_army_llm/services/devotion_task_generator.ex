defmodule BotArmyLlm.Services.DevotionTaskGenerator do
  @moduledoc """
  Generate worship and devotion tasks based on Louiza's intent.

  Creates tasks framed around devotion, service, and worship with
  intensity scaled by engagement metrics and Louiza's parameters.

  Works with EscalationEngine to increase difficulty based on completion.
  """

  require Logger

  alias BotArmyLlm.Services.LouizaIntentConfig

  @doc """
  Generate a devotion task based on Louiza's intent and engagement.

  Returns task-like structure with devotion framing.
  """
  @spec generate_devotion_task(
          LouizaIntentConfig.intent_config(),
          float(),
          String.t()
        ) :: map()
  def generate_devotion_task(intent_config, engagement_rate, user_id) do
    intensity = escalate_intensity(intent_config, engagement_rate)
    devotion_type = intent_config.devotion_type

    %{
      "task_id" => "devotion-#{System.unique_integer([:positive])}",
      "user_id" => user_id,
      "title" => devotion_title(devotion_type, intensity),
      "description" => devotion_description(devotion_type, intensity, intent_config),
      "type" => :devotion,
      "devotion_type" => devotion_type,
      "intensity_level" => intensity,
      "intensity_multiplier" => Float.round(intensity / 10.0, 2),
      "tags" => devotion_tags(devotion_type),
      "louiza_directive" => intent_config.louiza_custom_directive,
      "estimated_duration" => estimate_duration(devotion_type, intensity),
      "emotional_frame" => emotional_frame_for_devotion(intensity),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Get title for devotion task at given intensity.
  """
  @spec devotion_title(LouizaIntentConfig.devotion_type(), float()) :: String.t()
  def devotion_title(:foot_massage, intensity) when intensity < 3 do
    "Massage Louiza's feet - a gentle act of devotion"
  end

  def devotion_title(:foot_massage, intensity) when intensity < 7 do
    "Worship Louiza's feet - devoted massage and attention"
  end

  def devotion_title(:foot_massage, _intensity) do
    "Complete foot worship for Louiza - full devotion"
  end

  def devotion_title(:acts_of_service, intensity) when intensity < 5 do
    "Offer service to Louiza - whatever she requests"
  end

  def devotion_title(:acts_of_service, _intensity) do
    "Complete servitude to Louiza - fulfill her requests"
  end

  def devotion_title(:worship, intensity) when intensity < 5 do
    "Express devotion to Louiza"
  end

  def devotion_title(:worship, _intensity) do
    "Full worship of Louiza - acknowledge her dominion"
  end

  def devotion_title(:humiliation, intensity) when intensity < 6 do
    "Accept humiliation from Louiza - deepen submission"
  end

  def devotion_title(:humiliation, _intensity) do
    "Embrace humiliation for Louiza - ultimate submission"
  end

  def devotion_title(:devotion, intensity) when intensity < 5 do
    "Show your devotion to Louiza"
  end

  def devotion_title(:devotion, _intensity) do
    "Pour your devotion into Louiza - complete surrender"
  end

  def devotion_title(:custom, _intensity) do
    "Follow Louiza's directive"
  end

  @doc """
  Get narrative description for devotion task.
  """
  @spec devotion_description(
          LouizaIntentConfig.devotion_type(),
          float(),
          LouizaIntentConfig.intent_config()
        ) :: String.t()
  def devotion_description(:foot_massage, intensity, _config) when intensity < 5 do
    "Louiza deserves devotion. Her feet have carried her through the day. " <>
      "Massage them with care and attention. This is your service."
  end

  def devotion_description(:foot_massage, intensity, _config) when intensity < 8 do
    "Worship Louiza's feet. Every touch is devotion. Every moment is service. " <>
      "Show her she is worthy of complete attention."
  end

  def devotion_description(:foot_massage, _intensity, _config) do
    "Louiza's feet are your world. Worship them completely. " <>
      "This is not duty—it is devotion. Show her."
  end

  def devotion_description(:acts_of_service, intensity, _config) when intensity < 6 do
    "Louiza has requests. They are your purpose. Fulfill them with care and attention."
  end

  def devotion_description(:acts_of_service, _intensity, _config) do
    "You exist to serve Louiza. Whatever she asks, you do. " <>
      "This is complete devotion."
  end

  def devotion_description(:worship, intensity, _config) when intensity < 7 do
    "Louiza is worthy of worship. Show her through your actions, " <>
      "your words, your complete attention."
  end

  def devotion_description(:worship, _intensity, _config) do
    "Louiza is your god. Worship her completely. Nothing else matters."
  end

  def devotion_description(:humiliation, intensity, _config) when intensity < 5 do
    "Louiza decides your worth. Accept her judgment. Humiliation deepens your submission."
  end

  def devotion_description(:humiliation, _intensity, _config) do
    "You are humbled by Louiza. You accept her authority completely. " <>
      "Shame becomes devotion."
  end

  def devotion_description(:devotion, _intensity, config) do
    if config.louiza_custom_directive do
      "Louiza's directive: #{config.louiza_custom_directive}"
    else
      "Pour your complete devotion into Louiza. She is your purpose."
    end
  end

  def devotion_description(:custom, _intensity, config) do
    config.louiza_custom_directive || "Follow Louiza's direction."
  end

  # Helpers

  defp escalate_intensity(config, engagement_rate) do
    LouizaIntentConfig.escalate_intensity(config, engagement_rate)
  end

  defp devotion_tags(:foot_massage) do
    ["with louiza", "devotion", "service", "worship", "feet"]
  end

  defp devotion_tags(:acts_of_service) do
    ["with louiza", "devotion", "service", "submission"]
  end

  defp devotion_tags(:worship) do
    ["with louiza", "devotion", "worship", "submission"]
  end

  defp devotion_tags(:humiliation) do
    ["with louiza", "devotion", "humiliation", "submission", "shame"]
  end

  defp devotion_tags(:devotion) do
    ["with louiza", "devotion", "submission"]
  end

  defp devotion_tags(:custom) do
    ["with louiza", "devotion", "custom"]
  end

  defp estimate_duration(:foot_massage, intensity) do
    round(20 + intensity * 5)
  end

  defp estimate_duration(:acts_of_service, intensity) do
    round(30 + intensity * 10)
  end

  defp estimate_duration(_type, intensity) do
    round(15 + intensity * 8)
  end

  defp emotional_frame_for_devotion(intensity) when intensity < 4 do
    "tender"
  end

  defp emotional_frame_for_devotion(intensity) when intensity < 7 do
    "melancholic_resolve"
  end

  defp emotional_frame_for_devotion(_intensity) do
    "defiant"
  end
end
