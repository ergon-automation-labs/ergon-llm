defmodule BotArmyLlm.TriageQueueTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.TriageQueue

  @now 1_700_000_000

  defp start(opts \\ []) do
    test = self()
    dispatch = fn item -> send(test, {:dispatched, item.id}) end
    clock = fn _unit -> @now end

    {:ok, pid} =
      TriageQueue.start_link(
        Keyword.merge([name: nil, dispatch: dispatch, clock: clock, tick_ms: 0, slots: 2], opts)
      )

    pid
  end

  defp item(id, lane, attrs \\ %{}) do
    Map.merge(%{id: id, lane: lane, enqueued_at: @now}, attrs)
  end

  test "starting the queue says so, with its mode and slots" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start(mode: :cloud, auto_mode: true, slots: 3)
      end)

    assert log =~ "[TriageQueue] started: mode=cloud auto_mode=true slots=3"
  end

  test "a tick dispatches the top-ranked items up to the free slots and keeps the rest" do
    q = start()
    TriageQueue.enqueue(q, item("bg", "background"))
    TriageQueue.enqueue(q, item("int", "interactive"))
    TriageQueue.enqueue(q, item("urg", "urgent"))

    status = TriageQueue.tick(q)

    assert_receive {:dispatched, "urg"}
    assert_receive {:dispatched, "int"}
    refute_received {:dispatched, "bg"}
    assert status.depth == 1
    assert status.last_tick_at == @now
  end

  test "in-flight work holds slots until it completes" do
    q = start(slots: 1)
    TriageQueue.enqueue(q, item("a", "interactive"))
    TriageQueue.enqueue(q, item("b", "interactive"))

    TriageQueue.tick(q)
    assert_receive {:dispatched, "a"}
    refute_received {:dispatched, "b"}

    # the dispatch task casts :done when it returns; a second tick then has a free slot
    Process.sleep(20)
    TriageQueue.tick(q)
    assert_receive {:dispatched, "b"}
  end

  test "triage mode holds cloud-only work and reports it as waiting" do
    q = start()
    TriageQueue.set_mode(q, :triage)
    TriageQueue.enqueue(q, item("cloud", "urgent", %{cloud_only: true}))
    TriageQueue.enqueue(q, item("local", "background"))

    status = TriageQueue.tick(q)

    assert_receive {:dispatched, "local"}
    refute_received {:dispatched, "cloud"}
    assert status.waiting_for_cloud == 1
    assert status.depth == 1
  end

  test "by default the queue runs each item's own work" do
    test = self()
    {:ok, q} = TriageQueue.start_link(name: nil, clock: fn _ -> @now end, tick_ms: 0, slots: 1)
    TriageQueue.enqueue(q, item("w", "interactive", %{work: fn -> send(test, :ran) end}))
    TriageQueue.tick(q)
    assert_receive :ran
  end

  defp scripted_probe(states) do
    {:ok, agent} = Agent.start_link(fn -> states end)

    fn ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {[:closed], []}
      end)
    end
  end

  test "automatic mode goes to triage after two ticks of no closed cloud breaker, and back after two closed" do
    probe =
      scripted_probe([
        [:open, :open, :open],
        [:open, :open, :open],
        [:closed, :open, :open],
        [:closed, :open, :open]
      ])

    q = start(auto_mode: true, cloud_probe: probe)

    assert TriageQueue.tick(q).mode == :cloud
    assert TriageQueue.tick(q).mode == :triage
    assert TriageQueue.tick(q).mode == :triage
    assert TriageQueue.tick(q).mode == :cloud
  end

  test "a single flap does not toggle the mode" do
    probe =
      scripted_probe([[:open, :open, :open], [:closed, :open, :open], [:open, :open, :open]])

    q = start(auto_mode: true, cloud_probe: probe)

    for _ <- 1..3, do: TriageQueue.tick(q)
    assert TriageQueue.status(q).mode == :cloud
  end

  test "a claim is won once and is not released by the answer going out" do
    q = start()
    assert TriageQueue.claim(q, "r1", :dispatch)
    refute TriageQueue.claim(q, "r1", :ack)
  end

  test "claims older than an hour are pruned on a tick" do
    {:ok, clock} = Agent.start_link(fn -> @now end)

    {:ok, q} =
      TriageQueue.start_link(
        name: nil,
        clock: fn _ -> Agent.get(clock, & &1) end,
        tick_ms: 0,
        slots: 0
      )

    assert TriageQueue.claim(q, "old", :dispatch)
    Agent.update(clock, &(&1 + 3_601))
    TriageQueue.tick(q)
    assert TriageQueue.claim(q, "old", :ack)
  end

  test "status reports depth by lane and the oldest wait" do
    q = start(slots: 0)
    TriageQueue.enqueue(q, item("old", "background", %{enqueued_at: @now - 600}))
    TriageQueue.enqueue(q, item("new", "interactive"))

    status = TriageQueue.status(q)
    assert status.depth == 2
    assert status.by_lane == %{"urgent" => 0, "interactive" => 1, "background" => 1}
    assert status.oldest_wait_s == 600
  end

  test "background items beyond the bound are shed, and the count is kept" do
    q = start(slots: 0, shed_bound: 2)
    for n <- 1..4, do: TriageQueue.enqueue(q, item("bg#{n}", "background"))

    status = TriageQueue.tick(q)
    assert status.depth == 2
    assert status.shed_total == 2
  end

  describe "an item whose caller will not wait" do
    defp clocked(start_at) do
      {:ok, agent} = Agent.start_link(fn -> start_at end)
      {agent, fn _unit -> Agent.get(agent, & &1) end}
    end

    test "is removed at its expiry and told so, and never dispatched" do
      {clock_agent, clock} = clocked(@now)
      q = start(clock: clock, slots: 0)
      test = self()

      TriageQueue.enqueue(
        q,
        item("sync", "interactive", %{
          expires_at: @now + 30,
          on_expire: fn -> send(test, {:expired, "sync"}) end
        })
      )

      TriageQueue.tick(q)
      refute_received {:expired, "sync"}

      Agent.update(clock_agent, fn _ -> @now + 30 end)
      status = TriageQueue.tick(q)

      assert_receive {:expired, "sync"}
      assert status.depth == 0
      assert status.expired_total == 1
      refute_received {:dispatched, "sync"}
    end

    test "an item without an expiry waits as long as it takes" do
      {clock_agent, clock} = clocked(@now)
      q = start(clock: clock, slots: 0)

      TriageQueue.enqueue(q, item("job", "interactive"))
      Agent.update(clock_agent, fn _ -> @now + 86_400 end)

      assert TriageQueue.tick(q).depth == 1
    end

    test "one that is dispatched before its expiry is not expired afterwards" do
      {clock_agent, clock} = clocked(@now)
      q = start(clock: clock)
      test = self()

      TriageQueue.enqueue(
        q,
        item("fast", "interactive", %{
          expires_at: @now + 30,
          on_expire: fn -> send(test, {:expired, "fast"}) end
        })
      )

      TriageQueue.tick(q)
      assert_receive {:dispatched, "fast"}
      Agent.update(clock_agent, fn _ -> @now + 60 end)
      TriageQueue.tick(q)
      refute_received {:expired, "fast"}
    end
  end

  describe "kick on enqueue" do
    # A dispatch that holds its slot for a while, like a model generating.
    defp holding(ms) do
      test = self()

      fn item ->
        send(test, {:dispatched, item.id})
        Process.sleep(ms)
      end
    end

    test "off (the default), an item waits for the tick" do
      q = start()
      TriageQueue.enqueue(q, item("a", "interactive"))
      refute_receive {:dispatched, "a"}, 50
    end

    test "on, an item that finds a free slot runs at once" do
      q = start(kick: true)
      TriageQueue.enqueue(q, item("a", "interactive"))
      assert_receive {:dispatched, "a"}, 200
    end

    test "on, an item that finds no free slot still waits, and runs when one frees" do
      q = start(kick: true, slots: 1, dispatch: holding(150))
      TriageQueue.enqueue(q, item("a", "interactive"))
      TriageQueue.enqueue(q, item("b", "interactive"))
      assert_receive {:dispatched, "a"}, 200
      refute_receive {:dispatched, "b"}, 50
      Process.sleep(200)
      TriageQueue.tick(q)
      assert_receive {:dispatched, "b"}, 200
    end

    test "on, a higher lane arriving does not displace a running item, it goes first in line" do
      q = start(kick: true, slots: 1, dispatch: holding(150))
      TriageQueue.enqueue(q, item("bg", "background"))
      assert_receive {:dispatched, "bg"}, 200
      TriageQueue.enqueue(q, item("low", "background"))
      TriageQueue.enqueue(q, item("urg", "urgent"))
      refute_receive {:dispatched, "urg"}, 50
      Process.sleep(200)
      TriageQueue.tick(q)
      assert_receive {:dispatched, "urg"}, 200
      refute_received {:dispatched, "low"}
    end
  end
end
