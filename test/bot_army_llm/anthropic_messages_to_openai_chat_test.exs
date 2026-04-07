defmodule BotArmyLlm.AnthropicMessagesToOpenaiChatTest do
  use ExUnit.Case, async: true

  alias BotArmyLlm.AnthropicMessagesToOpenaiChat

  test "plain user + assistant" do
    payload = %{
      "messages" => [
        %{"role" => "user", "content" => "hi"},
        %{"role" => "assistant", "content" => "hello"}
      ]
    }

    assert {:ok, %{messages: msgs, tools: []}} = AnthropicMessagesToOpenaiChat.to_chat_completion_request(payload)

    assert msgs == [
             %{"role" => "user", "content" => "hi"},
             %{"role" => "assistant", "content" => "hello"}
           ]
  end

  test "tools array maps to OpenAI tools" do
    payload = %{
      "messages" => [%{"role" => "user", "content" => "x"}],
      "tools" => [
        %{
          "name" => "get_weather",
          "description" => "Weather",
          "input_schema" => %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}}
        }
      ]
    }

    assert {:ok, %{messages: [_], tools: [tool]}} =
             AnthropicMessagesToOpenaiChat.to_chat_completion_request(payload)

    assert tool["type"] == "function"
    assert get_in(tool, ["function", "name"]) == "get_weather"
    assert get_in(tool, ["function", "parameters"])["type"] == "object"
  end

  test "assistant tool_use → tool_calls" do
    payload = %{
      "messages" => [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "I'll check."},
            %{"type" => "tool_use", "id" => "toolu_1", "name" => "get_weather", "input" => %{"city" => "Paris"}}
          ]
        }
      ]
    }

    assert {:ok, %{messages: [m], tools: []}} = AnthropicMessagesToOpenaiChat.to_chat_completion_request(payload)
    assert m["role"] == "assistant"
    assert m["content"] == "I'll check."
    [tc] = m["tool_calls"]
    assert tc["id"] == "toolu_1"
    assert get_in(tc, ["function", "name"]) == "get_weather"
    assert Jason.decode!(get_in(tc, ["function", "arguments"])) == %{"city" => "Paris"}
  end

  test "user tool_result → OpenAI tool messages" do
    payload = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "sunny"}
          ]
        }
      ]
    }

    assert {:ok, %{messages: [t], tools: []}} = AnthropicMessagesToOpenaiChat.to_chat_completion_request(payload)
    assert t["role"] == "tool"
    assert t["tool_call_id"] == "toolu_1"
    assert t["content"] == "sunny"
  end
end
