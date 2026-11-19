defmodule BotArmyLlm.DecideDoorTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  alias BotArmyLlm.NATS.Consumer

  @request %{
    "state" => "a private letter",
    "questions" => %{"q" => %{"type" => "noul", "instructions" => "x"}}
  }

  test "llm.decide is advertised and subscribed" do
    assert "llm.decide" in Consumer.advertised_subjects()
    assert "llm.decide" in Consumer.subscription_subjects()
  end

  test "a decision answers ok with Clef's answers, read from an envelope's payload" do
    decide = fn req ->
      send(self(), {:asked, req})

      {:ok,
       %{
         "where" => "local",
         "model" => "clef-flash",
         "answers" => %{"q" => %{"noul" => 0.9}},
         "usage" => %{}
       }}
    end

    reply = Consumer.decide_response(%{"event_id" => "e9", "payload" => @request}, decide)

    assert_received {:asked, @request}
    assert reply["event"] == "llm.decide.response"
    assert reply["event_id"] == "e9"
    assert reply["payload"]["ok"] == true
    assert reply["payload"]["answers"]["q"]["noul"] == 0.9
    assert reply["payload"]["where"] == "local"
    assert {:ok, _} = Jason.encode(reply)
  end

  test "a bare request (no envelope) is read as is" do
    decide = fn req -> send(self(), {:asked, req}) && {:ok, %{"answers" => %{}}} end
    Consumer.decide_response(@request, decide)
    assert_received {:asked, @request}
  end

  test "each refusal answers ok: false with its code, never the state" do
    cases = [
      {{:invalid_request, "state is required"}, "invalid_request"},
      {{:model_not_configured, {:clef, "large"}}, "model_not_configured"},
      {{:unknown_node, "mini"}, "unknown_node"},
      {{:circuit_open, :clef_local, 1000}, "circuit_open"},
      {{:clef_http, 404, "model not found"}, "clef_http"},
      {{:clef_unreachable, :econnrefused}, "unreachable"},
      {:clef_bad_answer, "bad_answer"},
      {:something_else, "error"}
    ]

    for {reason, code} <- cases do
      reply = Consumer.decide_response(@request, fn _ -> {:error, reason} end)
      assert reply["payload"]["ok"] == false
      assert reply["payload"]["error"]["code"] == code, "for #{inspect(reason)}"
      refute Jason.encode!(reply) =~ "a private letter"
    end
  end

  test "a crash inside the decision answers crashed instead of leaving the caller waiting" do
    reply = Consumer.decide_response(@request, fn _ -> raise "boom" end)
    assert reply["payload"]["ok"] == false
    assert reply["payload"]["error"]["code"] == "crashed"
  end
end
