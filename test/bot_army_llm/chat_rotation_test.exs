defmodule BotArmyLlm.ChatRotationTest do
  use ExUnit.Case
  @moduletag :nats

  alias BotArmyLlm.NATS.Consumer

  defmodule HealthyStub do
    @moduledoc false
    def node_status do
      [%{name: :air, healthy: true}, %{name: :mini, healthy: false}]
    end
  end

  defmodule UnreadableStub do
    @moduledoc false
    def node_status, do: raise("health checker is down")
  end

  defmodule RotatorStub do
    @moduledoc false
    # The call is synchronous, so self() is the test process and the assertion can
    # see exactly which nodes the rotator was offered. Mirrors the real rotator's
    # contract: the eligible list arrives as node names and a name comes back.
    def next(eligible) do
      send(self(), {:rotated, eligible})
      eligible |> List.first() |> to_string()
    end
  end

  setup do
    previous_health = Application.get_env(:bot_army_llm, :ollama_health_checker)
    previous_rotator = Application.get_env(:bot_army_llm, :node_rotator)

    on_exit(fn ->
      restore(:ollama_health_checker, previous_health)
      restore(:node_rotator, previous_rotator)
    end)

    :ok
  end

  describe "chat_opts/2 with the round-robin sentinel" do
    test "resolves the sentinel against the healthy nodes" do
      Application.put_env(:bot_army_llm, :ollama_health_checker, HealthyStub)
      Application.put_env(:bot_army_llm, :node_rotator, RotatorStub)

      opts = Consumer.chat_opts(%{"ollama_node" => "round-robin", "system" => "hi"}, "background")

      assert opts[:ollama_node] == "air"
      assert_received {:rotated, [:air]}
    end

    test "accepts the rotate/rotation spellings too" do
      Application.put_env(:bot_army_llm, :ollama_health_checker, HealthyStub)
      Application.put_env(:bot_army_llm, :node_rotator, RotatorStub)

      assert Consumer.chat_opts(%{"ollama_node" => "rotate"}, "background")[:ollama_node] == "air"
      assert_received {:rotated, [:air]}

      assert Consumer.chat_opts(%{"ollama_node" => "rotation"}, "background")[:ollama_node] ==
               "air"

      assert_received {:rotated, [:air]}
    end

    test "an unreadable health view leaves the sentinel in place so routing refuses" do
      Application.put_env(:bot_army_llm, :ollama_health_checker, UnreadableStub)
      Application.put_env(:bot_army_llm, :node_rotator, RotatorStub)

      opts = Consumer.chat_opts(%{"ollama_node" => "round-robin"}, "background")

      assert opts[:ollama_node] == "round-robin"
      refute_received {:rotated, _any}
    end

    test "no healthy node also leaves the sentinel in place" do
      Application.put_env(:bot_army_llm, :ollama_health_checker, __MODULE__.NoNodesStub)
      Application.put_env(:bot_army_llm, :node_rotator, RotatorStub)

      assert Consumer.chat_opts(%{"ollama_node" => "round-robin"}, "background")[:ollama_node] ==
               "round-robin"

      refute_received {:rotated, _any}
    end

    test "an explicitly named node is left alone" do
      Application.put_env(:bot_army_llm, :ollama_health_checker, UnreadableStub)
      Application.put_env(:bot_army_llm, :node_rotator, RotatorStub)

      opts = Consumer.chat_opts(%{"ollama_node" => "mini", "model" => "m"}, "background")

      assert opts[:ollama_node] == "mini"
      assert opts[:model] == "m"
      refute_received {:rotated, _any}
    end
  end

  defmodule NoNodesStub do
    @moduledoc false
    def node_status, do: [%{name: :air, healthy: false}, %{name: :mini, healthy: false}]
  end

  defp restore(key, nil), do: Application.delete_env(:bot_army_llm, key)
  defp restore(key, value), do: Application.put_env(:bot_army_llm, key, value)
end
