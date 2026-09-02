defmodule BotArmyLlm.RoutingEngine do
  @moduledoc """
  Authoritative domain for routing LLM requests to the best model based on capabilities.
  
  Instead of asking for a literal model (e.g., "claude-3-5-sonnet"), callers can
  request a capability (e.g., "high-reasoning").
  """

  @doc """
  Determine the best model for the requested capability.
  """
  def route(capability, model_override \\ nil) do
    if model_override && model_override != "auto" do
      {model_override, :override}
    else
      case capability do
        "high-reasoning" -> {get_best_model(:high_reasoning), :routed}
        "fast_cheap"     -> {get_best_model(:fast_cheap), :routed}
        "vision"         -> {get_best_model(:vision), :routed}
        _                -> {get_best_model(:general), :routed}
      end
    end
  end

  defp get_best_model(capability) do
    # This mapping can be moved to a config file or a database for dynamic updates
    config = Application.get_env(:bot_army_llm, :model_routing, %{
      high_reasoning: "claude-3-5-sonnet-20240620",
      fast_cheap: "gpt-4o-mini",
      vision: "claude-3-5-sonnet-20240620",
      general: "claude-3-5-sonnet-20240620"
    })

    Map.get(config, capability, "claude-3-5-sonnet-20240620")
  end
end
