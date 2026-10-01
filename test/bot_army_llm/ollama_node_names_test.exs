defmodule BotArmyLlm.OllamaNodeNamesTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLlm.OllamaHealthChecker

  describe "node_urls/2" do
    test "an unset list leaves the node with its single historical name" do
      assert OllamaHealthChecker.node_urls("", ["http://100.72.132.2:11434"]) ==
               ["http://100.72.132.2:11434"]

      assert OllamaHealthChecker.node_urls(nil, ["http://127.0.0.1:11434"]) ==
               ["http://127.0.0.1:11434"]
    end

    test "configured names come first, in the order written, then the historical name" do
      # Tailnet address first (works wherever the tailnet is up), LAN name second
      # (works on shared networks when it is not) — that order is the failover order.
      assert OllamaHealthChecker.node_urls(
               "http://100.72.132.2:11434,http://the-chosen-legend.local:11434",
               ["http://100.72.132.2:11434"]
             ) == [
               "http://100.72.132.2:11434",
               "http://the-chosen-legend.local:11434"
             ]
    end

    test "blank entries and surrounding whitespace are ignored" do
      assert OllamaHealthChecker.node_urls(
               " http://a:11434 ,, http://b:11434 ,",
               []
             ) == ["http://a:11434", "http://b:11434"]
    end

    test "a name repeated in both places appears once" do
      assert OllamaHealthChecker.node_urls("http://a:11434", ["http://a:11434", "http://b:11434"]) ==
               ["http://a:11434", "http://b:11434"]
    end

    test "an empty list is possible and means the node cannot be probed" do
      assert OllamaHealthChecker.node_urls("", []) == []
    end
  end
end
