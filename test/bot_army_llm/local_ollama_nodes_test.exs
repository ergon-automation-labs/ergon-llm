defmodule BotArmyLlm.LocalOllamaNodesTest do
  @moduledoc """
  A `local_ollama` model may name several nodes, and the work is spread across the healthy ones.

  Before this, an entry named one node (or "" for the best local one, which is always the laptop),
  so the GM and the RSS sieve could not use the second machine at all, and the machine they did use
  was the one out of memory. `nodes: ["mini", "air"]` offers both; the existing weighted rotator
  picks among the healthy ones, a node that is down is not offered, and one that refuses is passed
  over for the next.
  """

  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.LocalOllama

  defmodule Health do
    @moduledoc false
    def node_status do
      case Application.get_env(:bot_army_llm, :nodes_test_status) do
        :raise -> raise "health checker is down"
        status -> status
      end
    end
  end

  defmodule Rotator do
    @moduledoc false
    # Records what it was offered, and names the first offered node.
    def next(eligible) do
      send(Application.get_env(:bot_army_llm, :nodes_test_pid), {:offered, eligible})
      eligible |> List.first() |> to_string()
    end
  end

  defmodule PickingRotator do
    @moduledoc false
    # Names the node the test chose, so "the rotator decides" can be told from "the list's order".
    def next(eligible) do
      send(Application.get_env(:bot_army_llm, :nodes_test_pid), {:offered, eligible})
      Application.get_env(:bot_army_llm, :nodes_test_pick)
    end
  end

  defmodule BadRotator do
    @moduledoc false
    def next(_eligible), do: nil
  end

  @models Jason.encode!([
            %{"model" => "m-both", "nodes" => ["mini", "air"]},
            %{"model" => "m-air", "nodes" => ["air"]},
            %{"model" => "m-one", "node" => "mini"},
            %{"model" => "m-best", "node" => ""},
            %{"model" => "m-messy", "nodes" => ["mini", " ", 7, "mini", " air "]},
            %{"model" => "m-empty", "nodes" => []},
            %{"model" => "m-wins", "node" => "air", "nodes" => ["mini", "air"]}
          ])

  setup do
    System.put_env("LOCAL_OLLAMA_MODELS", @models)
    Application.put_env(:bot_army_llm, :ollama_health_checker, Health)
    Application.put_env(:bot_army_llm, :node_rotator, Rotator)
    Application.put_env(:bot_army_llm, :nodes_test_pid, self())
    Application.put_env(:bot_army_llm, :nodes_test_status, [])

    on_exit(fn ->
      System.delete_env("LOCAL_OLLAMA_MODELS")

      for key <- [:ollama_health_checker, :node_rotator, :nodes_test_pid, :nodes_test_status],
          do: Application.delete_env(:bot_army_llm, key)
    end)

    :ok
  end

  defp status(pairs),
    do: Enum.map(pairs, fn {name, healthy} -> %{name: name, healthy: healthy} end)

  describe "resolve/1 reads the nodes an entry offers" do
    test "a model that names several nodes offers all of them, and pins none" do
      assert {:ok, %{model: "m-both", node: nil, nodes: ["mini", "air"]}} =
               LocalOllama.resolve(model: "m-both")
    end

    test "an entry that names one node, or none, is exactly as it was" do
      assert {:ok, %{node: "mini", nodes: []}} = LocalOllama.resolve(model: "m-one")
      assert {:ok, %{node: nil, nodes: []}} = LocalOllama.resolve(model: "m-best")
    end

    test "blank, repeated and non-text names are dropped" do
      assert {:ok, %{nodes: ["mini", "air"]}} = LocalOllama.resolve(model: "m-messy")
    end

    test "an empty list is no list" do
      assert {:ok, %{node: nil, nodes: []}} = LocalOllama.resolve(model: "m-empty")
    end

    test "when an entry names both, the list wins and the single node is not pinned" do
      assert {:ok, %{node: nil, nodes: ["mini", "air"]}} = LocalOllama.resolve(model: "m-wins")
    end
  end

  describe "order_nodes/1" do
    test "puts the rotator's pick first and the rest after, in the configured order" do
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true, air: true))

      assert LocalOllama.order_nodes(["mini", "air"]) == ["mini", "air"]
      assert_received {:offered, ["mini", "air"]}
    end

    test "offers the rotator only the healthy nodes, and keeps the unhealthy as a last resort" do
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: false, air: true))

      assert LocalOllama.order_nodes(["mini", "air"]) == ["air", "mini"]
      assert_received {:offered, ["air"]}
    end

    test "a node the health checker does not know is never offered, but is still listed" do
      Application.put_env(:bot_army_llm, :nodes_test_status, status(air: true))

      assert LocalOllama.order_nodes(["mini", "air"]) == ["air", "mini"]
      assert_received {:offered, ["air"]}
    end

    test "nothing healthy keeps the configured order and asks no rotator" do
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: false, air: false))

      assert LocalOllama.order_nodes(["mini", "air"]) == ["mini", "air"]
      refute_received {:offered, _}
    end

    test "an unreadable health view is the configured order, not a guess" do
      Application.put_env(:bot_army_llm, :nodes_test_status, :raise)
      assert LocalOllama.order_nodes(["air", "mini"]) == ["air", "mini"]
    end

    test "a rotator that answers nothing is the configured order" do
      Application.put_env(:bot_army_llm, :node_rotator, BadRotator)
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true, air: true))

      assert LocalOllama.order_nodes(["mini", "air"]) == ["mini", "air"]
    end

    test "the rotator's pick leads even when it is not first in the configured order" do
      Application.put_env(:bot_army_llm, :node_rotator, PickingRotator)
      Application.put_env(:bot_army_llm, :nodes_test_pick, "air")
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true, air: true))
      on_exit(fn -> Application.delete_env(:bot_army_llm, :nodes_test_pick) end)

      assert LocalOllama.order_nodes(["mini", "air"]) == ["air", "mini"]
    end

    test "a pick that is not one of the configured nodes is refused, not obeyed" do
      Application.put_env(:bot_army_llm, :node_rotator, PickingRotator)
      Application.put_env(:bot_army_llm, :nodes_test_pick, "somewhere-else")
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true, air: true))
      on_exit(fn -> Application.delete_env(:bot_army_llm, :nodes_test_pick) end)

      assert LocalOllama.order_nodes(["mini", "air"]) == ["mini", "air"]
    end

    test "a single node is itself, with no rotation, and none at all is none" do
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true))

      assert LocalOllama.order_nodes(["mini"]) == ["mini"]
      assert LocalOllama.order_nodes([]) == []
      refute_received {:offered, _}
    end

    test "health names that are atoms match the configured names" do
      Application.put_env(:bot_army_llm, :nodes_test_status, [
        %{name: :mini, healthy: true},
        %{name: :air, healthy: false}
      ])

      assert LocalOllama.order_nodes(["air", "mini"]) == ["mini", "air"]
    end
  end

  describe "first_usable/2" do
    test "stops at the first node that accepts" do
      accept = fn node ->
        send(self(), {:tried, node})
        {:ok, {node, "http://#{node}"}}
      end

      assert {:ok, {"mini", "http://mini"}} = LocalOllama.first_usable(["mini", "air"], accept)
      assert_received {:tried, "mini"}
      refute_received {:tried, "air"}
    end

    test "passes over a node that refuses, to the next" do
      accept = fn
        "mini" -> {:error, {:node_unhealthy, "mini"}}
        "air" -> {:ok, {"air", "http://air"}}
      end

      assert {:ok, {"air", _}} = LocalOllama.first_usable(["mini", "air"], accept)
    end

    test "every node refusing is the last refusal, by name" do
      accept = fn node -> {:error, {:node_unhealthy, node}} end

      assert {:error, {:node_unhealthy, "air"}} =
               LocalOllama.first_usable(["mini", "air"], accept)
    end

    test "no nodes at all is an error, not a crash" do
      assert {:error, :no_nodes} = LocalOllama.first_usable([], fn _ -> {:ok, :never} end)
    end
  end

  describe "through the client: the node that is chosen is the node that is called" do
    # A node that answers /api/chat and says which it is.
    defp start_node(name) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()
      pid = spawn_link(fn -> serve(listen, parent, name) end)
      on_exit(fn -> :gen_tcp.close(listen) end)
      {port, pid}
    end

    defp serve(listen, parent, name) do
      case :gen_tcp.accept(listen, 5_000) do
        {:ok, sock} ->
          read_all(sock, "")
          send(parent, {:called, name})

          body =
            Jason.encode!(%{
              "message" => %{"role" => "assistant", "content" => "from #{name}"},
              "done" => true
            })

          :gen_tcp.send(
            sock,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
              "#{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
          )

          :gen_tcp.close(sock)
          serve(listen, parent, name)

        {:error, _} ->
          :ok
      end
    end

    defp read_all(sock, acc) do
      case :gen_tcp.recv(sock, 0, 2_000) do
        {:ok, chunk} ->
          acc = acc <> chunk

          case String.split(acc, "\r\n\r\n", parts: 2) do
            [h, b] ->
              case Regex.run(~r/content-length:\s*(\d+)/i, h) do
                [_, n] ->
                  if byte_size(b) >= String.to_integer(n), do: acc, else: read_all(sock, acc)

                nil ->
                  acc
              end

            _ ->
              read_all(sock, acc)
          end

        _ ->
          acc
      end
    end

    defmodule Wire do
      @moduledoc false
      # Names each node's address, and refuses the ones the test marks down.
      def node_status do
        Application.get_env(:bot_army_llm, :nodes_test_status)
      end

      def best_ollama_node(_complexity, node) do
        name = to_string(node)

        if name in Application.get_env(:bot_army_llm, :nodes_test_down, []) do
          {:error, {:node_unhealthy, name}}
        else
          {:ok,
           {Application.fetch_env!(:bot_army_llm, :nodes_test_urls)[name], "ignored-default"}}
        end
      end

      def best_ollama_node(_complexity), do: {:error, :not_used}
      def load_acceptable?, do: true
      def url_owner(_url), do: nil
    end

    setup do
      {mini_port, _} = start_node("mini")
      {air_port, _} = start_node("air")

      Application.put_env(:bot_army_llm, :ollama_health_checker, Wire)
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true, air: true))

      Application.put_env(:bot_army_llm, :nodes_test_urls, %{
        "mini" => "http://127.0.0.1:#{mini_port}",
        "air" => "http://127.0.0.1:#{air_port}"
      })

      on_exit(fn ->
        Application.delete_env(:bot_army_llm, :nodes_test_urls)
        Application.delete_env(:bot_army_llm, :nodes_test_down)
      end)

      :ok
    end

    test "a multi-node model is answered by the node the rotator picked" do
      assert {:ok, %{completion: "from mini"}} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "m-both")

      assert_received {:called, "mini"}
      refute_received {:called, "air"}
    end

    test "the rotator, not the list's order, decides which node is called" do
      Application.put_env(:bot_army_llm, :node_rotator, PickingRotator)
      Application.put_env(:bot_army_llm, :nodes_test_pick, "air")
      on_exit(fn -> Application.delete_env(:bot_army_llm, :nodes_test_pick) end)

      assert {:ok, %{completion: "from air"}} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "m-both")

      assert_received {:called, "air"}
      refute_received {:called, "mini"}
    end

    test "when the first node refuses, the next one answers" do
      Application.put_env(:bot_army_llm, :nodes_test_down, ["mini"])

      assert {:ok, %{completion: "from air"}} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "m-both")

      assert_received {:called, "air"}
      refute_received {:called, "mini"}
    end

    test "every node refusing is an error naming one, and nothing is called" do
      Application.put_env(:bot_army_llm, :nodes_test_down, ["mini", "air"])

      assert {:error, _} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "m-both")

      refute_received {:called, _}
    end

    test "a single-node model is still that one node, whatever the rotator would say" do
      assert {:ok, %{completion: "from mini"}} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "m-one")

      refute_received {:offered, _}
    end

    test "a model offered only on air is never sent to mini" do
      Application.put_env(:bot_army_llm, :nodes_test_status, status(mini: true, air: true))

      assert {:ok, %{completion: "from air"}} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "m-air")

      refute_received {:called, "mini"}
    end
  end
end
