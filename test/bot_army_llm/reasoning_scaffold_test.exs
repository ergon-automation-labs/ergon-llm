defmodule BotArmyLlm.ReasoningScaffoldTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLlm.ReasoningScaffold

  describe "wrap/2" do
    test "passes through plain prompt when no reasoning mode" do
      assert ReasoningScaffold.wrap("What is 2+2?") == "What is 2+2?"
    end

    test "passes through plain prompt when reasoning_mode is nil" do
      assert ReasoningScaffold.wrap("What is 2+2?", reasoning_mode: nil) == "What is 2+2?"
    end

    test "prepends chain-of-thought instructions" do
      result = ReasoningScaffold.wrap("What is 2+2?", reasoning_mode: :chain_of_thought)
      assert String.contains?(result, "Think step-by-step")
      assert String.ends_with?(result, "What is 2+2?")
    end

    test "prepends ReAct instructions" do
      result = ReasoningScaffold.wrap("What is 2+2?", reasoning_mode: :react)
      assert String.contains?(result, "ReAct")
      assert String.ends_with?(result, "What is 2+2?")
    end
  end

  describe "wrap_messages/2" do
    test "passes through messages when no reasoning mode" do
      messages = [%{"role" => "user", "content" => "Hello"}]
      assert ReasoningScaffold.wrap_messages(messages) == messages
    end

    test "injects system message for chain-of-thought" do
      messages = [%{"role" => "user", "content" => "Hello"}]
      result = ReasoningScaffold.wrap_messages(messages, reasoning_mode: :chain_of_thought)

      assert length(result) == 2
      assert hd(result)["role"] == "system"
      assert String.contains?(hd(result)["content"], "Think step-by-step")
      assert Enum.at(result, 1)["role"] == "user"
    end

    test "prepends to existing system message" do
      messages = [
        %{"role" => "system", "content" => "You are helpful."},
        %{"role" => "user", "content" => "Hello"}
      ]

      result = ReasoningScaffold.wrap_messages(messages, reasoning_mode: :react)

      assert length(result) == 2
      assert hd(result)["role"] == "system"
      assert String.contains?(hd(result)["content"], "ReAct")
      assert String.contains?(hd(result)["content"], "You are helpful.")
    end

    test "handles empty messages list" do
      result = ReasoningScaffold.wrap_messages([], reasoning_mode: :chain_of_thought)
      assert length(result) == 1
      assert hd(result)["role"] == "system"
    end
  end
end
