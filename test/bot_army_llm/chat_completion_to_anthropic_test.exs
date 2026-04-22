defmodule BotArmyLlm.ChatCompletionToAnthropicTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.ChatCompletionToAnthropic

  test "text-only completion" do
    body =
      Jason.encode!(%{
        "id" => "gen-1",
        "model" => "x/y",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Hello"}
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
      })

    assert {:ok, json} = ChatCompletionToAnthropic.from_chat_completion_body(body, "x/y")
    out = Jason.decode!(json)
    assert [%{"type" => "text", "text" => "Hello"}] = out["content"]
    assert out["stop_reason"] == "end_turn"
  end

  test "tool_calls → Anthropic tool_use blocks" do
    body =
      Jason.encode!(%{
        "id" => "gen-2",
        "model" => "x/y",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{"name" => "foo", "arguments" => ~s({"a":1})}
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4}
      })

    assert {:ok, json} = ChatCompletionToAnthropic.from_chat_completion_body(body, nil)
    out = Jason.decode!(json)
    assert out["stop_reason"] == "tool_use"
    [block] = out["content"]
    assert block["type"] == "tool_use"
    assert block["id"] == "call_abc"
    assert block["name"] == "foo"
    assert block["input"] == %{"a" => 1}
  end
end
