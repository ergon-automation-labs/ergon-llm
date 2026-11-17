defmodule BotArmyLlm.ExecutionLaneTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.ExecutionLane

  test "Ollama cloud models are cloud and ordinary Ollama models are local" do
    assert ExecutionLane.classify(:ollama, "glm-5.1:cloud") == "cloud"
    assert ExecutionLane.classify(:ollama, "glm-5.1-cloud") == "cloud"
    assert ExecutionLane.classify(:ollama, "qwen3.5-uncensored:27B") == "local"
  end

  test "cloud providers are cloud without needing a model suffix" do
    assert ExecutionLane.classify(:anthropic, "claude-sonnet-4-5") == "cloud"
    assert ExecutionLane.classify(:openrouter, "some/model") == "cloud"
    assert ExecutionLane.classify("blackbox", "some-model") == "cloud"
  end

  test "local fallbacks stay local" do
    assert ExecutionLane.classify(:local_fallback, "deterministic_fallback") == "local"
    assert ExecutionLane.classify(:deterministic_fallback, nil) == "local"
  end

  test "an absent provider is not guessed local" do
    assert ExecutionLane.classify(nil, "claude-sonnet-4-5") == "unknown"
    assert ExecutionLane.classify(nil, nil) == "unknown"
    assert ExecutionLane.classify(:not_a_provider, "ordinary-model") == "unknown"
  end

  test "a cloud suffix is recognised even without a provider" do
    assert ExecutionLane.classify(nil, "deepseek-v4.1-flash:cloud") == "cloud"
  end

  test "from_result reads the reply map the bridge already receives" do
    assert ExecutionLane.from_result(%{
             "provider" => "ollama",
             "model_used" => "glm-5.1:cloud"
           }) == "cloud"

    assert ExecutionLane.from_result(%{
             "provider" => "ollama",
             "model_used" => "qwen3.5-uncensored:27B"
           }) == "local"
  end

  test "the lane list is closed and stable" do
    assert ExecutionLane.lanes() == ["cloud", "local", "unknown"]
  end
end
