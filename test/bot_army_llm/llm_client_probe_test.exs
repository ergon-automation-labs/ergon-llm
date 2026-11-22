defmodule BotArmyLlm.LlmClientProbeTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.LlmClient

  test "a provider with no running breaker is skipped, not probed" do
    # No breaker process is started in tests, so its state is unknown: never probe on a guess.
    assert :skipped = LlmClient.probe_provider(:openrouter)
    assert :skipped = LlmClient.probe_provider(:blackbox)
  end

  test "only cloud providers can be probed" do
    assert :skipped = LlmClient.probe_provider(:ollama)
    assert :skipped = LlmClient.probe_provider(:not_a_provider)
  end
end
