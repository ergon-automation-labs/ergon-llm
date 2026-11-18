defmodule BotArmyLlm.TriageAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.TriageAdmission

  test "build_item reads sender, model type, and the explicit cloud flag" do
    item =
      TriageAdmission.build_item(
        %{"request_id" => "r1", "sender" => "user", "model_type" => "uncensored", "cloud_only" => true},
        "interactive",
        fn -> :ok end
      )

    assert item.id == "r1"
    assert item.lane == "interactive"
    assert item.sender == :user
    assert item.local_only
    assert item.cloud_only
    assert is_function(item.work, 0)
  end

  test "defaults: system sender, no pins, a token estimate from the payload size" do
    item = TriageAdmission.build_item(%{"request_id" => "r2", "query" => "hello"}, "background", fn -> :ok end)

    assert item.sender == :system
    refute item.local_only
    refute item.cloud_only
    assert item.est_tokens > 0
  end

  test "triage is off unless explicitly enabled" do
    refute TriageAdmission.enabled?()
  end
end

defmodule BotArmyLlm.TriageAdmissionFlowTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.{JobStore, TriageAdmission, TriageQueue}

  setup do
    unless Process.whereis(JobStore), do: start_supervised!({JobStore, []})
    :ok
  end

  defp queue(name, slots) do
    {:ok, _} =
      TriageQueue.start_link(
        name: name,
        slots: slots,
        tick_ms: 0,
        clock: fn _ -> System.system_time(:second) end
      )

    name
  end

  test "a request still waiting after the ack window gets a queued reply with its job id" do
    server = queue(:flow_wait_q, 0)
    test = self()

    :ok =
      TriageAdmission.admit(%{"request_id" => "req-wait"}, "interactive",
        reply: fn m -> send(test, {:reply, m}) end,
        compute: fn -> %{"ok" => true, "answer" => "later"} end,
        server: server,
        ack_after_ms: 20
      )

    assert_receive {:reply, %{"status" => "queued", "job_id" => "req-wait"} = ack}, 1_000
    assert ack["poll_subject"] == "llm.job.status"
    assert {:ok, _job} = JobStore.get("req-wait")
  end

  test "a request dispatched before the ack window is answered directly, with no queued reply" do
    server = queue(:flow_fast_q, 2)
    test = self()

    :ok =
      TriageAdmission.admit(%{"request_id" => "req-fast"}, "interactive",
        reply: fn m -> send(test, {:reply, m}) end,
        compute: fn -> %{"ok" => true, "answer" => "now"} end,
        server: server,
        ack_after_ms: 500
      )

    TriageQueue.tick(server)

    assert_receive {:reply, %{"answer" => "now"}}, 1_000
    refute_receive {:reply, %{"status" => "queued"}}, 700
  end
end
