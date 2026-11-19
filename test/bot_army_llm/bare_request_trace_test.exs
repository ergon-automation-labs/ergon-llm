defmodule BotArmyLlm.BareRequestTraceTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  import ExUnit.CaptureLog

  alias BotArmyLlm.NATS.Consumer

  @body %{
    "source" => "some_bot",
    "model" => "m",
    "prompt_context" => %{"prompt" => "SECRET TEXT"}
  }

  test "the line names the subject, the caller's own source/model, and which keys it sent" do
    line =
      Consumer.bare_trace_line(
        "llm.request.chat",
        "_INBOX.abcdefghijk.1",
        @body,
        [{"traceparent", "x"}],
        120
      )

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

  describe "caller_label/2" do
    @envelope %{
      "event_id" => "e",
      "source" => "briefing_bot",
      "source_node" => "briefing_bot@abby-air",
      "triggered_by" => "schedule.tick"
    }

    test "an enveloped request is labelled by the sender's own source, node and trigger" do
      assert Consumer.caller_label(@envelope, "llm.request.chat") ==
               "briefing_bot@briefing_bot@abby-air via schedule.tick"
    end

    test "a trigger equal to the source adds nothing" do
      env = %{@envelope | "triggered_by" => "briefing_bot"}
      assert Consumer.caller_label(env, "s") == "briefing_bot@briefing_bot@abby-air"
    end

    test "a bare body is labelled bare with the subject, never by its own `source` field" do
      assert Consumer.caller_label(%{"source" => "local_ollama"}, "llm.request.chat") ==
               "bare:llm.request.chat"
    end
  end

  test "a stamped sender wins over what the body says about itself" do
    sender = %{bot: "rss_polling", node: "rss_polling@mini"}
    assert Consumer.caller_label(@envelope, "s", sender) == "rss_polling@rss_polling@mini"

    assert Consumer.caller_label(%{"source" => "x"}, "s", sender) ==
             "rss_polling@rss_polling@mini"

    assert Consumer.caller_label(%{}, "s", %{bot: nil, node: nil}) == "bare:s"
  end

  test "the sender is read from the stamped headers, and absent headers name nobody" do
    headers = [
      {"x-correlation-id", "c"},
      {"x-source-bot", "briefing_bot"},
      {"x-source-node", "n"}
    ]

    assert Consumer.sender_from_headers(headers) == %{bot: "briefing_bot", node: "n"}
    assert Consumer.sender_from_headers([]) == %{bot: nil, node: nil}
    assert Consumer.sender_from_headers(nil) == %{bot: nil, node: nil}
    assert Consumer.sender_from_headers([{"x-source-bot", ""}]) == %{bot: nil, node: nil}
  end

  test "the bare trace names the stamped sender, or says unstamped" do
    stamped = [{"x-source-bot", "rss_polling"}, {"x-source-node", "rss_polling@mini"}]

    assert Consumer.bare_trace_line("t", "_INBOX.x", %{}, stamped, 1) =~
             "from=rss_polling@rss_polling@mini"

    assert Consumer.bare_trace_line("t", "_INBOX.x", %{}, [], 1) =~ "from=unstamped"
  end

  test "chat_opts carries the caller label, and a caller cannot be anything but the stamped one" do
    opts = Consumer.chat_opts(%{"_caller" => "briefing_bot@air"}, "interactive")
    assert opts[:caller] == "briefing_bot@air"
    refute Keyword.has_key?(Consumer.chat_opts(%{}, "interactive"), :caller)
  end

  defmodule DownNode do
    @moduledoc false
    def best_ollama_node(_complexity), do: {:error, :down}
    def best_ollama_node(_complexity, _node), do: {:error, :down}
    def load_acceptable?, do: true
  end

  test "a provider failure line names the caller, and omits it when there is none" do
    Application.put_env(:bot_army_llm, :ollama_health_checker, DownNode)
    Application.put_env(:bot_army_llm, :provider_chain, [:ollama])

    on_exit(fn ->
      Application.delete_env(:bot_army_llm, :ollama_health_checker)
      Application.delete_env(:bot_army_llm, :provider_chain)
    end)

    messages = [%{"role" => "user", "content" => "hi"}]

    with_caller =
      capture_log(fn ->
        BotArmyLlm.LlmClient.complete_messages(messages, caller: "briefing_bot@air")
      end)

    assert with_caller =~ "Provider ollama failed (messages)"
    assert with_caller =~ "caller=briefing_bot@air"

    without =
      capture_log(fn -> BotArmyLlm.LlmClient.complete_messages(messages, []) end)

    assert without =~ "Provider ollama failed (messages)"
    refute without =~ "caller="
  end
end
