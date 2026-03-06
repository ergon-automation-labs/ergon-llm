defmodule BotArmyLlm.LlmClientTest do
  use ExUnit.Case

  alias BotArmyLlm.ComplexityScorer

  describe "ComplexityScorer.score/1" do
    test "short factual question scores :light" do
      assert ComplexityScorer.score("What is the capital of France?") == :light
    end

    test "yes/no question scores :light" do
      assert ComplexityScorer.score("yes or no") == :light
    end

    test "single heavy keyword with enough words scores :medium" do
      # 1 heavy keyword ("explain"), 13 words → :medium
      assert ComplexityScorer.score(
               "Can you explain how TCP/IP packet routing works in a computer network?"
             ) == :medium
    end

    test "multiple heavy keywords scores :heavy" do
      # "implement" + "function" → 2 heavy keywords → :heavy regardless of length
      assert ComplexityScorer.score(
               "Implement a binary search tree with insert and delete functions"
             ) == :heavy
    end

    test "3+ heavy keywords scores :heavy" do
      assert ComplexityScorer.score(
               "Design and implement an algorithm to analyze and compare two code architectures"
             ) == :heavy
    end

    test "200+ word prompt scores :heavy" do
      long_text = String.duplicate("word ", 210)
      assert ComplexityScorer.score(long_text) == :heavy
    end
  end

  describe "complete/2 with no cloud providers configured" do
    test "heavy prompt returns error when all providers unconfigured" do
      with_env(
        [
          {"BLACKBOX_API_KEY", nil},
          {"OPENROUTER_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil}
        ],
        fn ->
          # 200+ words → :heavy → skips Ollama, tries cloud only → all unconfigured
          heavy_prompt = String.duplicate("implement complex algorithm code ", 10)
          assert {:error, :no_providers_available} = BotArmyLlm.LlmClient.complete(heavy_prompt)
        end
      )
    end
  end

  # Temporarily override env vars for the duration of a test
  defp with_env(env_vars, func) do
    old_values = Enum.map(env_vars, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(env_vars, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      func.()
    after
      Enum.each(old_values, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
