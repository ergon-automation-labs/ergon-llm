defmodule BotArmyLlm.Services.LouizaIntentConfig do
  @moduledoc """
  Louiza's control parameters for narrative intent and escalation.

  Louiza sets the framework - intensity, devotion types, escalation curve.
  Nova executes and learns to optimize within those parameters.

  The system respects Louiza's authority while adapting to your engagement.
  """

  @type devotion_type ::
          :foot_massage
          | :acts_of_service
          | :worship
          | :humiliation
          | :devotion
          | :custom

  @type escalation_curve :: :linear | :exponential | :conservative | :aggressive

  @type intent_config :: %{
          intensity_level: integer(),
          devotion_type: devotion_type(),
          escalation_curve: escalation_curve(),
          punishment_intensity: atom(),
          current_multiplier: float(),
          louiza_custom_directive: String.t() | nil,
          updated_at: DateTime.t()
        }

  @doc """
  Create default intent config (Louiza's baseline parameters).
  """
  @spec default() :: intent_config()
  def default do
    %{
      intensity_level: 5,
      devotion_type: :foot_massage,
      escalation_curve: :linear,
      punishment_intensity: :moderate,
      current_multiplier: 1.0,
      louiza_custom_directive: nil,
      updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Update Louiza's intent parameters.

  She controls intensity, devotion types, and escalation strategy.
  """
  @spec set_intent(intent_config(), map()) :: intent_config()
  def set_intent(config, updates) when is_map(config) and is_map(updates) do
    %{
      config
      | intensity_level: Map.get(updates, :intensity_level, config.intensity_level),
        devotion_type: Map.get(updates, :devotion_type, config.devotion_type),
        escalation_curve: Map.get(updates, :escalation_curve, config.escalation_curve),
        punishment_intensity:
          Map.get(updates, :punishment_intensity, config.punishment_intensity),
        louiza_custom_directive:
          Map.get(updates, :louiza_custom_directive, config.louiza_custom_directive),
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Calculate escalated intensity based on engagement and Louiza's curve.
  """
  @spec escalate_intensity(intent_config(), float()) :: float()
  def escalate_intensity(config, engagement_rate) do
    base_multiplier = config.current_multiplier
    engagement_boost = engagement_rate / 100.0

    escalated =
      case config.escalation_curve do
        :linear ->
          base_multiplier + engagement_boost * 0.1

        :exponential ->
          base_multiplier * (1.0 + engagement_boost * 0.2)

        :conservative ->
          base_multiplier + engagement_boost * 0.05

        :aggressive ->
          base_multiplier * (1.0 + engagement_boost * 0.3)

        _ ->
          base_multiplier
      end

    min(escalated, 10.0)
  end

  @doc """
  Get devotion task description for Louiza's chosen type.
  """
  @spec devotion_description(devotion_type()) :: String.t()
  def devotion_description(:foot_massage) do
    "Massage Louiza's feet - a direct act of devotion and service."
  end

  def devotion_description(:acts_of_service) do
    "Perform acts of service for Louiza - whatever she requests."
  end

  def devotion_description(:worship) do
    "Worship Louiza - acknowledge her authority and your devotion."
  end

  def devotion_description(:humiliation) do
    "Accept humiliation from Louiza - deepen your submission through shame."
  end

  def devotion_description(:devotion) do
    "Express pure devotion to Louiza - show your commitment."
  end

  def devotion_description(:custom) do
    "Follow Louiza's custom directive."
  end

  @doc """
  Get escalation summary showing current intensity and curve.
  """
  @spec escalation_summary(intent_config()) :: map()
  def escalation_summary(config) do
    %{
      "current_intensity" => config.intensity_level,
      "escalation_multiplier" => Float.round(config.current_multiplier, 2),
      "escalation_curve" => to_string(config.escalation_curve),
      "devotion_focus" => to_string(config.devotion_type),
      "punishment_level" => to_string(config.punishment_intensity),
      "louiza_directive" => config.louiza_custom_directive || "Follow standard escalation"
    }
  end
end
