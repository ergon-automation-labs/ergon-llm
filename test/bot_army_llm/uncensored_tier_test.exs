defmodule BotArmyLlm.UncensoredTierTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.NATS.Consumer
  alias BotArmyLlm.UncensoredTier

  @tiers Jason.encode!(%{
           "light" => %{"model" => "m-light", "node" => ""},
           "heavy" => %{"model" => "m-heavy", "node" => "mini"}
         })

  setup do
    System.put_env("OLLAMA_UNCENSORED_TIERS", @tiers)
    on_exit(fn -> System.delete_env("OLLAMA_UNCENSORED_TIERS") end)
    :ok
  end

  describe "apply/2" do
    test "a tier fills in the pillar's model and node" do
      assert {:ok, opts} = UncensoredTier.apply([uncensored_tier: :heavy], :uncensored)
      assert opts[:model] == "m-heavy"
      assert opts[:ollama_node] == "mini"
    end

    test "a blank node leaves the node to the router" do
      assert {:ok, opts} = UncensoredTier.apply([uncensored_tier: :light], :uncensored)
      assert opts[:model] == "m-light"
      refute Keyword.has_key?(opts, :ollama_node)
    end

    test "a model the caller already named wins, and so does a named node" do
      assert {:ok, opts} =
               UncensoredTier.apply(
                 [uncensored_tier: :heavy, model: "mine", ollama_node: "air"],
                 :uncensored
               )

      assert opts[:model] == "mine"
      assert opts[:ollama_node] == "air"
    end

    test "no tier leaves the request exactly as it was" do
      assert {:ok, [temperature: 0.5]} = UncensoredTier.apply([temperature: 0.5], :uncensored)
    end

    test "other complexities are never touched, even with a tier" do
      assert {:ok, [uncensored_tier: :heavy]} =
               UncensoredTier.apply([uncensored_tier: :heavy], :medium)
    end

    test "a tier that is not configured is refused by name, never answered by another model" do
      System.put_env("OLLAMA_UNCENSORED_TIERS", Jason.encode!(%{"light" => %{"model" => "m"}}))

      assert {:error, {:model_not_configured, {:uncensored, :heavy}}} =
               UncensoredTier.apply([uncensored_tier: :heavy], :uncensored)

      System.delete_env("OLLAMA_UNCENSORED_TIERS")

      assert {:error, {:model_not_configured, {:uncensored, :light}}} =
               UncensoredTier.apply([uncensored_tier: :light], :uncensored)
    end

    test "unreadable config is the same as unset" do
      for bad <- ["nope", "[]", ~s({"heavy":{"model":""}}), ~s({"heavy":"m"})] do
        System.put_env("OLLAMA_UNCENSORED_TIERS", bad)

        assert {:error, {:model_not_configured, {:uncensored, :heavy}}} =
                 UncensoredTier.apply([uncensored_tier: :heavy], :uncensored)
      end
    end
  end

  describe "chat_opts/2" do
    test "the tier is carried with the uncensored type" do
      opts =
        Consumer.chat_opts(
          %{"model_type" => "uncensored", "uncensored_tier" => "heavy"},
          "interactive"
        )

      assert opts[:uncensored_tier] == :heavy
      assert opts[:model_type] == :uncensored
    end

    test "a tier means nothing without the uncensored type, so it is not carried" do
      assert Keyword.get(
               Consumer.chat_opts(%{"uncensored_tier" => "heavy"}, "interactive"),
               :uncensored_tier
             ) == nil

      opts =
        Consumer.chat_opts(
          %{"model_type" => "heavy", "uncensored_tier" => "heavy"},
          "interactive"
        )

      assert Keyword.get(opts, :uncensored_tier) == nil
    end

    test "an unknown tier is dropped, not minted into an atom" do
      opts =
        Consumer.chat_opts(
          %{"model_type" => "uncensored", "uncensored_tier" => "huge"},
          "interactive"
        )

      assert Keyword.get(opts, :uncensored_tier) == nil
    end
  end

  test "through the client: an unconfigured tier is refused and trips no breaker" do
    System.delete_env("OLLAMA_UNCENSORED_TIERS")
    before = BotArmyLlm.CircuitBreaker.allow?(:ollama)

    assert {:error, {:model_not_configured, {:uncensored, :heavy}}} =
             BotArmyLlm.LlmClient.complete("hi", model_type: :uncensored, uncensored_tier: :heavy)

    assert BotArmyLlm.CircuitBreaker.allow?(:ollama) == before
  end
end
