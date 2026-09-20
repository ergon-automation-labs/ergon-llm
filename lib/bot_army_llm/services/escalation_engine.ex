defmodule BotArmyLlm.Services.EscalationEngine do
  @moduledoc """
  Manages escalation based on engagement and Louiza's intent.

  Tracks completion rates, calculates when to escalate, and updates
  intensity multipliers. Works with LouizaIntentConfig to respect
  her control parameters while adapting to your engagement.

  The loop: High completion → escalate → harder tasks → deeper dynamic
  """

  require Logger

  alias BotArmyLlm.Services.LouizaIntentConfig

  @doc """
  Calculate engagement rate from completion history.

  Returns percentage (0-100) of recent devotion tasks completed.
  """
  @spec calculate_engagement_rate([map()]) :: float()
  def calculate_engagement_rate(recent_tasks) when is_list(recent_tasks) do
    if length(recent_tasks) == 0 do
      0.0
    else
      completed = Enum.count(recent_tasks, &(&1["event_type"] == "task_completed"))
      shown = length(recent_tasks)
      completed / shown * 100
    end
  end

  @doc """
  Determine if should escalate based on engagement.

  Returns {:escalate, new_multiplier} or {:maintain, current_multiplier}
  """
  @spec should_escalate?(
          LouizaIntentConfig.intent_config(),
          [map()]
        ) :: {:escalate, float()} | {:maintain, float()}
  def should_escalate?(config, recent_events) do
    engagement_rate = calculate_engagement_rate(recent_events)
    current_multiplier = config.current_multiplier

    escalation_threshold = threshold_for_curve(config.escalation_curve)

    if engagement_rate >= escalation_threshold do
      new_multiplier = LouizaIntentConfig.escalate_intensity(config, engagement_rate)

      Logger.info(
        "Escalating: engagement #{Float.round(engagement_rate, 1)}% >= #{escalation_threshold}%"
      )

      {:escalate, new_multiplier}
    else
      {:maintain, current_multiplier}
    end
  end

  @doc """
  Update intent config with new multiplier if escalating.
  """
  @spec apply_escalation(
          LouizaIntentConfig.intent_config(),
          {:escalate, float()} | {:maintain, float()}
        ) :: LouizaIntentConfig.intent_config()
  def apply_escalation(config, {:escalate, new_multiplier}) do
    %{config | current_multiplier: new_multiplier, updated_at: DateTime.utc_now()}
  end

  def apply_escalation(config, {:maintain, _multiplier}) do
    config
  end

  @doc """
  Get escalation status for feedback display.
  """
  @spec escalation_status(
          LouizaIntentConfig.intent_config(),
          [map()]
        ) :: map()
  def escalation_status(config, recent_events) do
    engagement_rate = calculate_engagement_rate(recent_events)
    threshold = threshold_for_curve(config.escalation_curve)
    {status, new_multiplier} = should_escalate?(config, recent_events)

    %{
      "current_engagement_rate" => Float.round(engagement_rate, 1),
      "escalation_threshold" => threshold,
      "status" => status,
      "current_multiplier" => Float.round(config.current_multiplier, 2),
      "next_multiplier" => Float.round(new_multiplier, 2),
      "escalation_curve" => to_string(config.escalation_curve),
      "message" => escalation_message(status, engagement_rate, threshold, config.escalation_curve)
    }
  end

  # Helpers

  defp threshold_for_curve(:linear) do
    70.0
  end

  defp threshold_for_curve(:exponential) do
    65.0
  end

  defp threshold_for_curve(:conservative) do
    80.0
  end

  defp threshold_for_curve(:aggressive) do
    60.0
  end

  defp threshold_for_curve(_) do
    70.0
  end

  defp escalation_message(:escalate, engagement, _threshold, curve) do
    case curve do
      :aggressive ->
        "Louiza sees your devotion. The intensity deepens."

      :exponential ->
        "Your engagement drives escalation. Louiza increases the challenge."

      :conservative ->
        "Steady commitment. Louiza prepares the next phase."

      _ ->
        "You're ready for more. Louiza escalates."
    end
  end

  defp escalation_message(:maintain, engagement, threshold, _curve) do
    remaining = threshold - engagement
    "#{Float.round(remaining, 1)}% more engagement needed before escalation."
  end
end
