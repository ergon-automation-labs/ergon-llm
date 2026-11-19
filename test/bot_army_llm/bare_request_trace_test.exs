defmodule BotArmyLlm.BareRequestTraceTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  import ExUnit.CaptureLog

  alias BotArmyLlm.NATS.Consumer

  @body %{"source" => "some_bot", "model" => "m", "prompt_context" => %{"prompt" => "SECRET TEXT"}}

  test "the line names the subject, the caller's own source/model, and which keys it sent" do
    line =
      Consumer.bare_trace_line("llm.request.chat", "_INBOX.abcdefghijk.1", @body, [{"traceparent", "x"}], 120)

    assert line =~ "topic=llm.request.chat"
    assert line =~ "source=some_bot"
    assert line =~ "model=m"
    assert line =~ "keys=[model,prompt_context,source]"
    assert line =~ "headers=[traceparent]"
    assert line =~ "bytes=120"
    assert line =~ "reply_inbox=_INBOX.abcdef"
  end

  test "payload values other than the named fields are never in the line" do
    line = Consumer.bare_trace_line("llm.request.chat", "_INBOX.x", @body, [], 10)
    refute line =~ "SECRET TEXT"
  end

  test "one line per subject and source per minute, then a count" do
    log =
      capture_log(fn ->
        Consumer.trace_bare_request("t", "_INBOX.x", @body, [], 1, 0)
        Consumer.trace_bare_request("t", "_INBOX.x", @body, [], 1, 1_000)
        Consumer.trace_bare_request("t", "_INBOX.x", @body, [], 1, 2_000)
        Consumer.trace_bare_request("t", "_INBOX.x", @body, [], 1, 61_000)
      end)

    assert length(String.split(log, "[BareRequest]")) - 1 == 2
    assert log =~ "(+0 since last line)"
    assert log =~ "(+2 since last line)"
  end

  test "a different source is a different line" do
    log =
      capture_log(fn ->
        Consumer.trace_bare_request("t", "_INBOX.x", %{"source" => "a"}, [], 1, 0)
        Consumer.trace_bare_request("t", "_INBOX.x", %{"source" => "b"}, [], 1, 1)
      end)

    assert log =~ "source=a"
    assert log =~ "source=b"
  end

  test "a body that is not an object still traces, with no fields" do
    assert bare = Consumer.bare_trace_line("t", "_INBOX.x", [1, 2], [], 5)
    assert bare =~ "keys=[-]"
  end
end
