defmodule BotArmyLlm.TriageStatusDoorTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  alias BotArmyLlm.NATS.Consumer

  @summary %{
    mode: :triage,
    depth: 3,
    by_lane: %{"urgent" => 0, "interactive" => 1, "background" => 2},
    oldest_wait_s: 42,
    waiting_for_cloud: 1,
    in_flight: 2,
    slots: 2,
    shed_total: 0,
    dispatched_total: 17,
    last_tick_at: 1_795_112_000
  }

  test "llm.triage.status is advertised and subscribed" do
    assert "llm.triage.status" in Consumer.advertised_subjects()
    assert "llm.triage.status" in Consumer.subscription_subjects()
  end

  test "a running queue answers its summary, mode as a string, with running: true" do
    reply = Consumer.triage_status_response(%{"event_id" => "e1"}, fn -> @summary end)

    assert reply["event"] == "llm.triage.status.response"
    assert reply["event_id"] == "e1"
    assert reply["source"] == "bot_army_llm"

    payload = reply["payload"]
    assert payload["running"] == true
    assert is_boolean(payload["enabled"])
    assert payload["mode"] == "triage"
    assert payload["depth"] == 3
    assert payload["by_lane"] == %{"urgent" => 0, "interactive" => 1, "background" => 2}
    assert payload["oldest_wait_s"] == 42
    assert payload["waiting_for_cloud"] == 1
    assert payload["in_flight"] == 2
    assert payload["dispatched_total"] == 17
    assert payload["last_tick_at"] == 1_795_112_000

    assert {:ok, _} = Jason.encode(reply)
  end

  test "a queue that is not running answers running: false instead of crashing" do
    reply = Consumer.triage_status_response(%{}, fn -> nil end)

    assert reply["payload"]["running"] == false
    assert is_boolean(reply["payload"]["enabled"])
    refute Map.has_key?(reply["payload"], "mode")
  end

  test "the live lookup answers running: false when no queue process exists" do
    refute Process.whereis(BotArmyLlm.TriageQueue)
    assert Consumer.triage_status_response(%{})["payload"]["running"] == false
  end
end
