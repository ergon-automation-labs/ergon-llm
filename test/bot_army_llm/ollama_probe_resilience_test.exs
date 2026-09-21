defmodule BotArmyLlm.OllamaProbeResilienceTest do
  # async: false — the last test suspends the globally registered checker.
  use ExUnit.Case, async: false
  @moduletag :core

  # The health checker used to run its probe cycle INSIDE the GenServer, with a
  # 120 s per-request timeout. One slow node (a 27B loading, a stalled Tailscale
  # link) therefore held the lock for minutes while best_ollama_node/2 calls —
  # which use the default 5 s GenServer timeout — queued behind it and took their
  # callers down. Routing stopped answering for the whole fleet, and the only
  # visible symptom was an LLM request that never got a reply.
  #
  # These tests pin the property, not the implementation: a wedged node may make
  # ROUTING say "no healthy node", it may never make routing stop answering.
  #
  # Hermetic: the "wedged node" is a local socket that accepts and never replies.
  alias BotArmyLlm.OllamaHealthChecker

  @immediate_us 1_000_000
  # Long enough to outlive the slowest assertion, short enough to die with the test.
  @wedged_probe_timeout_ms 5_000

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test_pid = self()

    # Accept the probe's connection and hold it open without ever answering —
    # the TCP equivalent of an ollama that is busy loading a 27B model.
    acceptor =
      spawn(fn ->
        case :gen_tcp.accept(listen, 30_000) do
          {:ok, _socket} ->
            send(test_pid, :probe_connected)
            Process.sleep(:infinity)

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port}
  end

  defp wedged_state(port) do
    %{
      nodes: %{
        air: %{
          url: "http://127.0.0.1:#{port}",
          latency_ms: nil,
          last_probe_at: nil,
          healthy: false,
          memory_pressure: nil,
          cpu_load: nil,
          enabled: true,
          explicit_only: false,
          default_model: nil,
          probe_model: "gemma3:1b"
        }
      },
      probe_model: "gemma3:1b",
      probe_timeout_ms: @wedged_probe_timeout_ms,
      probe_in_flight: false,
      degraded_latency_ms: 8_000
    }
  end

  test "a probe cycle returns without waiting for the probe", %{port: port} do
    {elapsed_us, {:noreply, state}} =
      :timer.tc(fn -> OllamaHealthChecker.handle_info(:probe, wedged_state(port)) end)

    assert state.probe_in_flight
    assert elapsed_us < @immediate_us
    # The probe is off the call path and genuinely stuck, not merely fast to fail.
    assert_receive :probe_connected, 1_000
  end

  test "routing still answers while a probe is stuck", %{port: port} do
    {:noreply, probing} = OllamaHealthChecker.handle_info(:probe, wedged_state(port))

    {elapsed_us, reply} =
      :timer.tc(fn ->
        OllamaHealthChecker.handle_call({:best_node, :uncensored, "air"}, self(), probing)
      end)

    assert elapsed_us < @immediate_us
    # An honest refusal about the node — not a hang, and not a silent fallthrough.
    assert {:reply, {:error, {:node_unhealthy, "air"}}, _state} = reply
  end

  test "a tick that lands during a probe is skipped, never stacked", %{port: port} do
    in_flight = %{wedged_state(port) | probe_in_flight: true}

    assert {:noreply, ^in_flight} = OllamaHealthChecker.handle_info(:probe, in_flight)
  end

  test "a probe result lands and clears the in-flight marker", %{port: port} do
    {:noreply, probing} = OllamaHealthChecker.handle_info(:probe, wedged_state(port))
    assert probing.probe_in_flight

    probed = %{probing | nodes: %{probing.nodes | air: %{probing.nodes.air | healthy: true}}}

    assert {:noreply, settled} = OllamaHealthChecker.handle_info({:probe_result, probed}, probing)
    refute settled.probe_in_flight
    assert settled.nodes.air.healthy
  end

  test "best_ollama_node/2 returns an error instead of exiting when the checker has no reply" do
    # A checker that does not answer within the caller's budget is the old failure
    # mode in miniature: it must surface as an error tuple, never as an exit in a
    # live request handler.
    assert Process.whereis(OllamaHealthChecker)

    previous = System.get_env("OLLAMA_HEALTH_CALL_TIMEOUT_MS")
    System.put_env("OLLAMA_HEALTH_CALL_TIMEOUT_MS", "200")
    :sys.suspend(OllamaHealthChecker)

    try do
      assert {:error, :health_checker_busy} =
               OllamaHealthChecker.best_ollama_node(:uncensored, "air")
    after
      :sys.resume(OllamaHealthChecker)
      if previous, do: System.put_env("OLLAMA_HEALTH_CALL_TIMEOUT_MS", previous)
      unless previous, do: System.delete_env("OLLAMA_HEALTH_CALL_TIMEOUT_MS")
    end
  end
end
