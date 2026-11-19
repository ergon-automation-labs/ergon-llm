defmodule BotArmyLlm.LocalOllamaTest do
  use ExUnit.Case, async: false

  @moduletag :core

  alias BotArmyLlm.{ExecutionLane, LocalOllama}
  alias BotArmyLlm.NATS.Consumer

  @models Jason.encode!([
            %{"model" => "m-small", "node" => nil},
            %{"model" => "m-mid", "node" => ""},
            %{"model" => "m-big", "node" => "mini"}
          ])

  setup do
    System.put_env("LOCAL_OLLAMA_MODELS", @models)

    on_exit(fn ->
      System.delete_env("LOCAL_OLLAMA_MODELS")
      System.delete_env("LOCAL_OLLAMA_TIMEOUT_MS")
      System.delete_env("LOCAL_OLLAMA_MAX_TIMEOUT_MS")
    end)

    :ok
  end

  describe "resolve/1" do
    test "the first configured model is the default, on the best local node" do
      assert {:ok, %{model: "m-small", node: nil, timeout_ms: 180_000}} = LocalOllama.resolve([])
      assert {:ok, %{model: "m-small"}} = LocalOllama.resolve(model: "auto")
    end

    test "a blank node is the best local node, a named node is pinned" do
      assert {:ok, %{node: nil}} = LocalOllama.resolve(model: "m-mid")
      assert {:ok, %{node: "mini"}} = LocalOllama.resolve(model: "m-big")
    end

    test "no model is named in code: unset config fails closed" do
      System.delete_env("LOCAL_OLLAMA_MODELS")

      assert {:error, {:model_not_configured, :local_ollama}} = LocalOllama.resolve([])
      assert {:error, {:model_not_configured, :local_ollama}} = LocalOllama.resolve(model: "m-small")
    end

    test "unreadable config is the same as unset" do
      for bad <- ["not json", "[]", ~s([{"node":"mini"}]), ~s({"model":"x"})] do
        System.put_env("LOCAL_OLLAMA_MODELS", bad)
        assert {:error, {:model_not_configured, :local_ollama}} = LocalOllama.resolve([])
      end
    end

    test "the ceiling and default timeout are config too" do
      System.put_env("LOCAL_OLLAMA_MAX_TIMEOUT_MS", "50000")
      System.put_env("LOCAL_OLLAMA_TIMEOUT_MS", "30000")
      assert {:ok, %{timeout_ms: 50_000}} = LocalOllama.resolve(timeout_ms: 400_000)
      assert {:ok, %{timeout_ms: 30_000}} = LocalOllama.resolve([])
    end

    test "a model off the allowlist is refused by name, with what is allowed" do
      assert {:error, {:model_not_allowed, "gemma3:1b", ["m-small", "m-mid", "m-big"]}} =
               LocalOllama.resolve(model: "gemma3:1b")
    end

    test "timeout_ms is honoured and clamped" do
      assert {:ok, %{timeout_ms: 45_000}} = LocalOllama.resolve(timeout_ms: 45_000)
      assert {:ok, %{timeout_ms: 600_000}} = LocalOllama.resolve(timeout_ms: 9_999_999)
      assert {:ok, %{timeout_ms: 180_000}} = LocalOllama.resolve(timeout_ms: -1)
    end
  end

  describe "chat_opts/2" do
    test "source local_ollama carries the source and the timeout" do
      opts =
        Consumer.chat_opts(
          %{"source" => "local_ollama", "timeout_ms" => 120_000, "model" => "m"},
          "interactive"
        )

      assert opts[:source] == :local_ollama
      assert opts[:timeout_ms] == 120_000
    end

    test "timeout_ms is ignored without the source" do
      opts = Consumer.chat_opts(%{"timeout_ms" => 120_000}, "interactive")
      refute Keyword.has_key?(opts, :timeout_ms)
      refute Keyword.has_key?(opts, :source)
    end

    test "an unknown source is dropped, not minted into an atom" do
      opts = Consumer.chat_opts(%{"source" => "nonsense-source"}, "interactive")
      refute Keyword.has_key?(opts, :source)
    end
  end

  test "an unconfigured source is refused through the client and trips no breaker" do
    System.delete_env("LOCAL_OLLAMA_MODELS")
    before = BotArmyLlm.CircuitBreaker.allow?(:local_ollama)

    assert {:error, {:model_not_configured, :local_ollama}} =
             BotArmyLlm.LlmClient.complete("hi", source: :local_ollama)

    assert BotArmyLlm.CircuitBreaker.allow?(:local_ollama) == before
  end

  test "the lane is local" do
    assert ExecutionLane.classify(:local_ollama, "m-small") == "local"
  end

  describe "the provider, through the client" do
    test "a model off the allowlist is refused and does not trip any breaker" do
      before = BotArmyLlm.CircuitBreaker.allow?(:local_ollama)

      assert {:error, {:model_not_allowed, "gemma3:1b", _}} =
               BotArmyLlm.LlmClient.complete("hi", source: :local_ollama, model: "gemma3:1b")

      assert BotArmyLlm.CircuitBreaker.allow?(:local_ollama) == before
    end
  end
end
