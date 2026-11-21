defmodule BotArmyLlm.TriageAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.TriageAdmission

  test "build_item reads sender, model type, and the explicit cloud flag" do
    item =
      TriageAdmission.build_item(
        %{
          "request_id" => "r1",
          "sender" => "user",
          "model_type" => "uncensored",
          "cloud_only" => true
        },
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
    item =
      TriageAdmission.build_item(%{"request_id" => "r2", "query" => "hello"}, "background", fn ->
        :ok
      end)

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
      TriageAdmission.admit(
        %{"request_id" => "req-wait", "accepts_queued" => true},
        "interactive",
        reply: fn m -> send(test, {:reply, m}) end,
        compute: fn -> %{"ok" => true, "answer" => "later"} end,
        server: server,
        ack_after_ms: 20
      )

    assert_receive {:reply, %{"status" => "queued", "job_id" => "req-wait"} = ack}, 1_000
    assert ack["poll_subject"] == "llm.job.status"
    assert {:ok, _job} = JobStore.get("req-wait")
  end

  test "a caller that did not opt in never gets a queued reply, only its answer" do
    server = queue(:flow_optout_q, 0)
    test = self()

    :ok =
      TriageAdmission.admit(%{"request_id" => "req-old"}, "background",
        reply: fn m -> send(test, {:reply, m}) end,
        compute: fn -> %{"ok" => true, "answer" => "later"} end,
        server: server,
        ack_after_ms: 20
      )

    refute_receive {:reply, %{"status" => "queued"}}, 300
  end

  test "an async job runs through the queue and its result lands with the job id" do
    server = queue(:flow_job_q, 2)
    test = self()

    :ok =
      TriageAdmission.admit(%{"request_id" => "ignored"}, "background",
        id: "job-42",
        ack: false,
        reply: fn result -> send(test, {:job_done, result}) end,
        compute: fn -> %{"ok" => true, "answer" => "from the queue"} end,
        server: server
      )

    TriageQueue.tick(server)
    assert_receive {:job_done, %{"answer" => "from the queue"}}, 1_000
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

  describe "a sync request whose caller will not wait forever" do
    defp clocked_queue(name, slots) do
      {:ok, clock} = Agent.start_link(fn -> 1_700_000_000 end)

      {:ok, _} =
        TriageQueue.start_link(
          name: name,
          slots: slots,
          tick_ms: 0,
          clock: fn _ -> Agent.get(clock, & &1) end
        )

      {name, clock}
    end

    test "expires in the queue with an error reply, and its work never runs" do
      {server, clock} = clocked_queue(:flow_expire_q, 0)
      test = self()

      :ok =
        TriageAdmission.admit(%{"request_id" => "req-gone"}, "interactive",
          reply: fn m -> send(test, {:reply, m}) end,
          compute: fn -> send(test, :ran) && %{"ok" => true} end,
          server: server,
          expire_after_ms: 20_000
        )

      TriageQueue.tick(server)
      refute_receive {:reply, _}, 50

      Agent.update(clock, &(&1 + 21))
      TriageQueue.tick(server)

      assert_receive {:reply,
                      %{"ok" => false, "error" => "expired_in_queue", "request_id" => "req-gone"}},
                     1_000

      refute_received :ran
    end

    test "a request dispatched in time is answered, and not expired later" do
      {server, clock} = clocked_queue(:flow_inTime_q, 2)
      test = self()

      :ok =
        TriageAdmission.admit(%{"request_id" => "req-ok"}, "interactive",
          reply: fn m -> send(test, {:reply, m}) end,
          compute: fn -> %{"ok" => true, "answer" => "in time"} end,
          server: server,
          expire_after_ms: 20_000
        )

      TriageQueue.tick(server)
      assert_receive {:reply, %{"answer" => "in time"}}, 1_000

      Agent.update(clock, &(&1 + 60))
      TriageQueue.tick(server)
      refute_receive {:reply, %{"error" => "expired_in_queue"}}, 100
    end

    test "an async job, which names no expiry, waits as long as it takes" do
      {server, clock} = clocked_queue(:flow_nojobexpire_q, 0)
      test = self()

      :ok =
        TriageAdmission.admit(%{"request_id" => "x"}, "background",
          id: "job-slow",
          ack: false,
          reply: fn m -> send(test, {:reply, m}) end,
          compute: fn -> %{"ok" => true} end,
          server: server
        )

      Agent.update(clock, &(&1 + 100_000))
      status = TriageQueue.tick(server)
      assert status.depth == 1
      refute_receive {:reply, _}, 50
    end

    test "the default expiry is configuration, and a caller's own deadline can only shorten it" do
      assert TriageAdmission.expire_after_ms(%{}) == TriageAdmission.default_expire_ms()
      assert TriageAdmission.expire_after_ms(%{"deadline_ms" => 5_000}) == 5_000

      assert TriageAdmission.expire_after_ms(%{"deadline_ms" => 99_999_999}) ==
               TriageAdmission.default_expire_ms()

      assert TriageAdmission.expire_after_ms(%{"deadline_ms" => "soon"}) ==
               TriageAdmission.default_expire_ms()

      assert TriageAdmission.expire_after_ms(%{"deadline_ms" => 0}) ==
               TriageAdmission.default_expire_ms()
    end
  end
end
