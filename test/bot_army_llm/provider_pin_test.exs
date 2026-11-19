defmodule BotArmyLlm.ProviderPinTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.NATS.Consumer
  alias BotArmyLlm.ProviderPin

  @models Jason.encode!(%{
            "openrouter" => ["or/model-a", "or/model-b"],
            "anthropic" => ["an/model"]
          })
  @routes Jason.encode!(%{
            "sieve_bot" => %{"provider" => "local_ollama", "ignored" => "x"},
            "coach_bot" => %{"provider" => "openrouter", "model" => "or/model-a"},
            "tier_bot" => %{"model_type" => "uncensored", "uncensored_tier" => "heavy"}
          })

  setup do
    System.put_env("LLM_PROVIDER_MODELS", @models)
    System.put_env("LLM_ROUTES", @routes)

    on_exit(fn ->
      System.delete_env("LLM_PROVIDER_MODELS")
      System.delete_env("LLM_ROUTES")
    end)

    :ok
  end

  describe "parse/1" do
    test "a name or an ordered list of names" do
      assert ProviderPin.parse("openrouter") == {:ok, [:openrouter]}
      assert ProviderPin.parse(" OpenRouter ") == {:ok, [:openrouter]}
      assert ProviderPin.parse(["anthropic", "openrouter"]) == {:ok, [:anthropic, :openrouter]}
    end

    test "anything else is an error, never an atom" do
      for bad <- ["nope", ["openrouter", "nope"], [], 5, %{}, nil, [1]] do
        assert ProviderPin.parse(bad) == :error
      end
    end
  end

  describe "resolve/2" do
    @chain [:ollama, :blackbox, :openrouter, :anthropic]

    test "nothing pinned leaves the chain as it was" do
      assert ProviderPin.resolve(@chain, []) == @chain
    end

    test "a pin replaces the chain, in the order given" do
      assert ProviderPin.resolve(@chain, providers: [:anthropic, :openrouter]) ==
               [:anthropic, :openrouter]
    end

    test "local providers are always allowed, even when the chain would not list them" do
      assert ProviderPin.resolve([:ollama], providers: [:local_ollama]) == [:local_ollama]
    end

    test "a cloud provider outside the safe chain is refused: a pin cannot step around the rules" do
      # What an :uncensored request, or sensitive text, is reduced to.
      assert ProviderPin.resolve([:ollama], providers: [:openrouter]) ==
               {:error, {:provider_not_allowed, :openrouter}}
    end

    test "an unknown provider is a refusal carrying what was asked for" do
      assert ProviderPin.resolve(@chain, providers: {:invalid, "opnrouter"}) ==
               {:error, {:unknown_provider, "opnrouter"}}
    end

    test "a model must be on the provider's pillar allowlist" do
      assert ProviderPin.resolve(@chain, providers: [:openrouter], model: "or/model-b") ==
               [:openrouter]

      assert {:error, {:model_not_allowed, "or/other", :openrouter, ["or/model-a", "or/model-b"]}} =
               ProviderPin.resolve(@chain, providers: [:openrouter], model: "or/other")
    end

    test "with nothing allowlisted for a provider, no model is allowed for it" do
      assert {:error, {:model_not_allowed, "x", :blackbox, []}} =
               ProviderPin.resolve(@chain, providers: [:blackbox], model: "x")
    end

    test "a model name belongs to one provider, so a list with a model is refused" do
      assert ProviderPin.resolve(@chain,
               providers: [:openrouter, :anthropic],
               model: "or/model-a"
             ) ==
               {:error, {:model_needs_single_provider, "or/model-a"}}
    end

    test "no model, or auto, means the tier's own model" do
      assert ProviderPin.resolve(@chain, providers: [:openrouter], model: "auto") == [:openrouter]
    end
  end

  describe "model_for/2" do
    test "only a pinned, single, cloud provider with an allowlisted model" do
      assert ProviderPin.model_for(:openrouter, providers: [:openrouter], model: "or/model-a") ==
               "or/model-a"

      assert ProviderPin.model_for(:openrouter, model: "or/model-a") == nil

      assert ProviderPin.model_for(:openrouter,
               providers: [:openrouter, :anthropic],
               model: "or/model-a"
             ) == nil

      assert ProviderPin.model_for(:openrouter, providers: [:openrouter], model: "or/nope") == nil
      assert ProviderPin.model_for(:ollama, providers: [:ollama], model: "or/model-a") == nil
    end
  end

  describe "route_for/1" do
    test "only the known keys are taken" do
      assert ProviderPin.route_for("sieve_bot") == %{"provider" => "local_ollama"}
    end

    test "no route, no bot, or unreadable config is an empty route" do
      assert ProviderPin.route_for("nobody") == %{}
      assert ProviderPin.route_for(nil) == %{}
      System.put_env("LLM_ROUTES", "not json")
      assert ProviderPin.route_for("sieve_bot") == %{}
    end
  end

  describe "chat_opts/2" do
    test "the request names the provider" do
      assert Consumer.chat_opts(%{"provider" => "openrouter"}, "interactive")[:providers] ==
               [:openrouter]

      assert Consumer.chat_opts(%{"provider" => ["anthropic", "openrouter"]}, "interactive")[
               :providers
             ] ==
               [:anthropic, :openrouter]
    end

    test "a typo'd provider is carried as a refusal, not dropped" do
      assert Consumer.chat_opts(%{"provider" => "opnrouter"}, "interactive")[:providers] ==
               {:invalid, "opnrouter"}
    end

    test "a caller with a route gets its defaults" do
      opts = Consumer.chat_opts(%{"_caller_bot" => "coach_bot"}, "interactive")
      assert opts[:providers] == [:openrouter]
      assert opts[:model] == "or/model-a"
    end

    test "a route can set the uncensored type and tier" do
      opts = Consumer.chat_opts(%{"_caller_bot" => "tier_bot"}, "interactive")
      assert opts[:model_type] == :uncensored
      assert opts[:uncensored_tier] == :heavy
    end

    test "the request always beats its route" do
      opts =
        Consumer.chat_opts(
          %{"_caller_bot" => "coach_bot", "provider" => "anthropic", "model" => "an/model"},
          "interactive"
        )

      assert opts[:providers] == [:anthropic]
      assert opts[:model] == "an/model"
    end

    test "a request that says source local_ollama is not re-routed" do
      opts =
        Consumer.chat_opts(
          %{"_caller_bot" => "coach_bot", "source" => "local_ollama"},
          "interactive"
        )

      assert opts[:source] == :local_ollama
      refute Keyword.has_key?(opts, :providers)
    end

    test "a caller with no route is untouched" do
      opts = Consumer.chat_opts(%{"_caller_bot" => "nobody"}, "interactive")
      refute Keyword.has_key?(opts, :providers)
    end
  end

  describe "through the client" do
    test "an :uncensored request cannot be pinned to a cloud provider, and no breaker is touched" do
      before = BotArmyLlm.CircuitBreaker.get_state(:openrouter).failures

      assert {:error, {:provider_not_allowed, :openrouter}} =
               BotArmyLlm.LlmClient.complete("hi",
                 model_type: :uncensored,
                 providers: [:openrouter]
               )

      assert {:error, {:provider_not_allowed, :openrouter}} =
               BotArmyLlm.LlmClient.complete_messages([%{"role" => "user", "content" => "hi"}],
                 model_type: :uncensored,
                 providers: [:openrouter]
               )

      # The failure count, not allow?/1: an open breaker's retry_after is a countdown.
      assert BotArmyLlm.CircuitBreaker.get_state(:openrouter).failures == before
    end

    test "a model off the allowlist is refused by name before any provider is called" do
      assert {:error, {:model_not_allowed, "or/other", :openrouter, _}} =
               BotArmyLlm.LlmClient.complete("hi", providers: [:openrouter], model: "or/other")
    end

    test "an unknown provider is refused by name" do
      assert {:error, {:unknown_provider, "nope"}} =
               BotArmyLlm.LlmClient.complete("hi", providers: {:invalid, "nope"})
    end
  end
end
