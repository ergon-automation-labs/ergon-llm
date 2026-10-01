defmodule BotArmyLlm.NodeQueueWiringTest do
  @moduledoc """
  The gate's own tests prove the mechanism. These prove the *wiring*: that a real
  local generation actually goes through it.

  No Ollama and no network are needed. A local TCP server accepts the connection
  and then never answers, which is all a hanging generation is from the client's
  side — so the slot is observably held for as long as the test wants.
  """
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.{LlmClient, NodeQueue}

  defmodule HangingNode do
    @moduledoc false
    def best_ollama_node(complexity), do: best_ollama_node(complexity, nil)

    def best_ollama_node(_complexity, _node) do
      {:ok, {Application.fetch_env!(:bot_army_llm, :hanging_node_url), "test-model"}}
    end

    def load_acceptable?, do: true
  end

  setup do
    name = :"node_queue_wiring_#{System.unique_integer([:positive])}"
    Application.put_env(:bot_army_llm, :node_queue_server, name)
    Application.put_env(:bot_army_llm, :ollama_health_checker, HangingNode)

    on_exit(fn ->
      Application.delete_env(:bot_army_llm, :node_queue_server)
      Application.delete_env(:bot_army_llm, :ollama_health_checker)
      Application.delete_env(:bot_army_llm, :hanging_node_url)
    end)

    :ok
  end

  defp start_queue(opts) do
    name = Application.fetch_env!(:bot_army_llm, :node_queue_server)
    {:ok, pid} = NodeQueue.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  # Accepts and then holds the socket open without ever replying.
  defp start_hanging_node do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    holder = spawn(fn -> accept_forever(listen, []) end)

    on_exit(fn ->
      Process.exit(holder, :kill)
      :gen_tcp.close(listen)
    end)

    url = "http://127.0.0.1:#{port}"
    Application.put_env(:bot_army_llm, :hanging_node_url, url)
    url
  end

  defp accept_forever(listen, held) do
    case :gen_tcp.accept(listen, 30_000) do
      {:ok, socket} -> accept_forever(listen, [socket | held])
      {:error, _reason} -> :ok
    end
  end

  defp status(url), do: Map.get(NodeQueue.status(), url, %{running: [], waiting: []})

  defp wait_until(fun, tries \\ 200) do
    Enum.reduce_while(1..tries, false, fn _n, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  test "a real local generation holds its node's slot, and the next one waits" do
    start_queue(max_wait_ms: 5_000)
    url = start_hanging_node()

    first = Task.async(fn -> LlmClient.complete("hi") end)
    assert wait_until(fn -> status(url).running != [] end), "the first call must take the slot"

    second = Task.async(fn -> LlmClient.complete("hi") end)

    assert wait_until(fn -> length(status(url).waiting) == 1 end),
           "a second call must wait behind the first, not run beside it"

    assert status(url).running |> length() == 1

    Task.shutdown(first, :brutal_kill)
    Task.shutdown(second, :brutal_kill)
  end

  test "a local-only job that cannot get a slot refuses instead of hanging" do
    start_queue(max_wait_ms: 100)
    url = start_hanging_node()

    first = Task.async(fn -> LlmClient.complete("hi") end)
    assert wait_until(fn -> status(url).running != [] end)

    # :uncensored is local-only by design, so there is no cloud fallback to hide
    # behind — the caller has to be told.
    refused = Task.async(fn -> LlmClient.complete("hi", model_type: :uncensored) end)

    # The gate refused it (logged with the cause) and the caller got an error
    # rather than a hang. The terminal reason is this bot's long-standing
    # `:no_providers_available` — a refusal and a dead provider are not
    # distinguished to the caller, which is worth fixing separately.
    assert {:error, :no_providers_available} = Task.await(refused, 5_000)
    assert status(url).waiting == []

    Task.shutdown(first, :brutal_kill)
  end
end
