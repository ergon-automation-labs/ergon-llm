defmodule BotArmyLlm.ClaudePassthroughChainTest do
  use ExUnit.Case, async: true

  alias BotArmyLlm.ClaudePassthroughChain

  test "parse_chain_string/1 default-style list" do
    assert {:ok, [:openrouter, :anthropic, :ollama]} =
             ClaudePassthroughChain.parse_chain_string("openrouter,anthropic,ollama")
  end

  test "parse_chain_string/1 trims and lowercases" do
    assert {:ok, [:blackbox, :openrouter]} =
             ClaudePassthroughChain.parse_chain_string(" Blackbox , OPENROUTER ")
  end

  test "parse_chain_string/1 unknown step" do
    assert {:error, {:unknown_claude_chain_step, "lambda"}} =
             ClaudePassthroughChain.parse_chain_string("anthropic,lambda")
  end
end
