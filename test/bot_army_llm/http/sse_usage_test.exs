defmodule BotArmyLlm.Http.SseUsageTest do
  use ExUnit.Case, async: true

  alias BotArmyLlm.Http.SseUsage

  test "last_usage_from_sse/1 reads usage from message_delta data line" do
    sse = """
    event: message_start
    data: {"type":"message_start"}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"output_tokens":20}}

    """

    assert SseUsage.last_usage_from_sse(sse) == {10, 20}
  end

  test "last_usage_from_sse/1 prefers last data line with usage" do
    sse = """
    data: {"usage":{"input_tokens":1,"output_tokens":2}}
    data: {"usage":{"input_tokens":5,"output_tokens":7}}
    """

    assert SseUsage.last_usage_from_sse(sse) == {5, 7}
  end

  test "last_usage_from_sse/1 returns nils when no usage" do
    assert SseUsage.last_usage_from_sse("data: {}\n") == {nil, nil}
  end
end
