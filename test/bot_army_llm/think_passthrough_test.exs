defmodule BotArmyLlm.ThinkPassthroughTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  # A reasoning model on Ollama's default settings spends a short budget on hidden
  # thinking and answers with an empty `content`. `think: false` is the caller's way
  # to ask for the direct answer, and it has to survive chat_opts and both wire formats.
  alias BotArmyLlm.LlmClient
  alias BotArmyLlm.NATS.Consumer

  describe "chat_opts/2" do
    test "a boolean think is passed on, true or false" do
      assert Consumer.chat_opts(%{"think" => false}, "background")[:think] == false
      assert Consumer.chat_opts(%{"think" => true}, "background")[:think] == true
    end

    test "anything but a boolean is dropped, not coerced" do
      for bad <- ["false", "no", 0, 1, nil, %{}] do
        refute Keyword.has_key?(Consumer.chat_opts(%{"think" => bad}, "background"), :think)
      end
    end

    test "absent means the opt is absent, so the model's own default applies" do
      refute Keyword.has_key?(Consumer.chat_opts(%{}, "background"), :think)
    end
  end

  describe "think_fields/2" do
    test "native Ollama takes think as a boolean" do
      assert %{"think" => false} = LlmClient.think_fields([think: false], :native)
      assert %{"think" => true} = LlmClient.think_fields([think: true], :native)
      assert %{} == LlmClient.think_fields([], :native)
    end

    test "the OpenAI-compatible wire turns thinking off with reasoning_effort none" do
      assert %{"reasoning_effort" => "none"} = LlmClient.think_fields([think: false], :openai)
      assert %{} == LlmClient.think_fields([think: true], :openai)
      assert %{} == LlmClient.think_fields([], :openai)
    end
  end
end
