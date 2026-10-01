defmodule BotArmyLlm.NodeQueueTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.NodeQueue

  setup do
    on_exit(fn ->
      Application.delete_env(:bot_army_llm, :node_queue_server)
      Process.delete(:llm_job_id)
    end)

    :ok
  end

  # The gate is a singleton in production, so a test takes over the name it
  # answers to (the same env seam the health checker and rotator use) and starts
  # its own instance with limits small enough to observe.
  defp start_queue(opts \\ []) do
    name = :"node_queue_test_#{System.unique_integer([:positive])}"
    Application.put_env(:bot_army_llm, :node_queue_server, name)
    {:ok, pid} = NodeQueue.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  # A separate process holding a slot, so releasing it can depend on something
  # other than the test process finishing.
  defp start_holder(key) do
    test = self()

    pid =
      spawn(fn ->
        :ok = NodeQueue.acquire(key)
        send(test, {:holding, self()})

        receive do
          :release ->
            NodeQueue.release(key)
            send(test, {:released, self()})
        end
      end)

    assert_receive {:holding, ^pid}, 1_000
    pid
  end

  defp wait_until(fun, tries \\ 100) do
    Enum.reduce_while(1..tries, false, fn _n, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  test "one generation at a time: a second job waits for the first" do
    start_queue(max_wait_ms: 5_000)
    holder = start_holder("http://air:11434")

    waiter = Task.async(fn -> NodeQueue.acquire("http://air:11434", "job-2") end)

    refute Task.yield(waiter, 100),
           "the second job must not hold the node while the first does"

    send(holder, :release)
    assert_receive {:released, ^holder}, 1_000
    assert :ok = Task.await(waiter, 1_000)
  end

  test "the wait list is bounded: a third job is refused, not queued forever" do
    start_queue(max_waiting: 1, max_wait_ms: 5_000)
    holder = start_holder("mini")

    waiter = Task.async(fn -> NodeQueue.acquire("mini", "job-2") end)
    assert wait_until(fn -> NodeQueue.status()["mini"].waiting == ["job-2"] end)

    assert {:error, :queue_full} = NodeQueue.acquire("mini", "job-3")
    assert NodeQueue.status()["mini"].running == ["pid:#{inspect(holder)}"]

    send(holder, :release)
    assert :ok = Task.await(waiter, 1_000)
  end

  test "a job that waits too long is told so instead of waiting forever" do
    start_queue(max_wait_ms: 150)
    holder = start_holder("air")

    waiter = Task.async(fn -> NodeQueue.acquire("air", "job-2") end)

    assert {:error, :queue_timeout} = Task.await(waiter, 1_000)
    assert NodeQueue.status()["air"].waiting == []

    send(holder, :release)
    assert_receive {:released, ^holder}, 1_000
  end

  test "a holder that dies without releasing frees its slot" do
    start_queue(max_wait_ms: 5_000)
    holder = start_holder("mini")

    Process.exit(holder, :kill)

    assert wait_until(fn -> NodeQueue.status()["mini"].running == [] end),
           "a crashed job must not wedge the node"

    assert :ok = NodeQueue.acquire("mini", "job-2")
    NodeQueue.release("mini")
  end

  test "waiting is per node: one busy node does not hold up the other" do
    start_queue(max_wait_ms: 5_000)
    start_holder("air")

    assert :ok = NodeQueue.acquire("mini", "job-2")
    NodeQueue.release("mini")
  end

  test "run/3 returns the work's own result and releases the slot" do
    start_queue()
    Process.put(:llm_job_id, "job-42")

    assert {:ok, :done} = NodeQueue.run("air", NodeQueue.queued_label(), fn -> {:ok, :done} end)
    assert NodeQueue.status()["air"].running == []

    assert_raise RuntimeError, "boom", fn ->
      NodeQueue.run("air", NodeQueue.queued_label(), fn -> raise "boom" end)
    end

    assert NodeQueue.status()["air"].running == []
  end

  test "a refusal comes back shaped like a provider error" do
    start_queue(max_concurrency: 1, max_waiting: 0)
    start_holder("air")

    assert {:error, :queue_full} =
             NodeQueue.run("air", "job-9", fn -> flunk("refused work must not run") end)
  end

  test "a missing queue runs the work anyway: a guard must not wedge the bot" do
    Application.put_env(:bot_army_llm, :node_queue_server, :node_queue_that_was_never_started)

    assert {:ok, :ran} = NodeQueue.run("air", nil, fn -> {:ok, :ran} end)
  end
end
