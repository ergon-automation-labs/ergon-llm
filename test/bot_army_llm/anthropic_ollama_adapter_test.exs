defmodule BotArmyLlm.AnthropicOllamaAdapterTest do
  use ExUnit.Case, async: true

  alias BotArmyLlm.AnthropicOllamaAdapter

  test "to_ollama_messages/1 maps system + user text" do
    payload = %{
      "model" => "claude-3",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "system" => "You are helpful."
    }

    assert {:ok, msgs} = AnthropicOllamaAdapter.to_ollama_messages(payload)

    assert msgs == [
             %{"role" => "system", "content" => "You are helpful."},
             %{"role" => "user", "content" => "hello"}
           ]
  end

  test "to_ollama_messages/1 rejects tools" do
    payload = %{
      "model" => "claude-3",
      "messages" => [%{"role" => "user", "content" => "hi"}],
      "tools" => [%{"name" => "x", "input_schema" => %{}}]
    }

    assert AnthropicOllamaAdapter.to_ollama_messages(payload) ==
             {:error, :tools_not_supported_on_ollama_fallback}
  end

  test "anthropic_json_from_ollama_chat/2 wraps Ollama response" do
    ollama = ~s({"model":"m","message":{"role":"assistant","content":"yo"},"eval_count":3,"prompt_eval_count":2})

    assert {:ok, json} = AnthropicOllamaAdapter.anthropic_json_from_ollama_chat(ollama, "m")

    {:ok, decoded} = Jason.decode(json)
    assert decoded["role"] == "assistant"
    assert decoded["usage"]["input_tokens"] == 2
    assert decoded["usage"]["output_tokens"] == 3
    assert hd(decoded["content"])["text"] == "yo"
  end
end
