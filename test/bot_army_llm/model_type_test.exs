defmodule BotArmyLlm.ModelTypeTest do
  @moduledoc """
  The `:uncensored` type is a promise about *who may answer*, not a difficulty.
  These tests pin that promise at each seam it crosses: the allowlist, the
  provider chain, and the payload→opts translation.

  Deliberately not `:integration`: everything here is pure or uses a mock health
  checker, so the invariant is enforced on every default test run, not only when
  someone remembers to pass `--include integration`.
  """
  use ExUnit.Case
  @moduletag :client

  import ExUnit.CaptureLog

  alias BotArmyLlm.{LlmClient, ModelType}
  alias BotArmyLlm.NATS.Consumer

  describe "ModelType.parse/1" do
    test "accepts every documented type as string or atom" do
      for type <- ModelType.all() do
        assert ModelType.parse(type) == {:ok, type}
        assert ModelType.parse(Atom.to_string(type)) == {:ok, type}
      end
    end

    test "is case- and whitespace-insensitive" do
      assert ModelType.parse("  Uncensored ") == {:ok, :uncensored}
      assert ModelType.parse("HEAVY") == {:ok, :heavy}
    end

    test "returns :error for unknown input instead of minting an atom" do
      assert ModelType.parse("uncensored_typo") == :error
      assert ModelType.parse(nil) == :error
      assert ModelType.parse(:mediumish) == :error
      assert ModelType.parse(42) == :error

      # The real hazard: an unbounded payload field becoming an atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom("uncensored_typo") end
    end

    test "only :uncensored is local-only" do
      assert ModelType.local_only?(:uncensored)
      refute ModelType.local_only?(:light)
      refute ModelType.local_only?(:medium)
      refute ModelType.local_only?(:heavy)
    end
  end

  describe "complete/2 with model_type: :uncensored" do
    # A spy, not a stub: the mock reports which complexity the client asked for,
    # so "the type reached the router" is observable without HTTP.
    defmodule SpyHealthChecker do
      def best_ollama_node(complexity) do
        send(:llm_model_type_spy, {:asked, complexity})
        {:error, :no_healthy_nodes}
      end

      def best_ollama_node(complexity, node) do
        send(:llm_model_type_spy, {:asked, complexity, node})
        {:error, :no_healthy_nodes}
      end

      def load_acceptable?, do: true
      def node_status, do: []
    end

    setup do
      Process.register(self(), :llm_model_type_spy)
      Application.put_env(:bot_army_llm, :ollama_health_checker, SpyHealthChecker)
      # An open circuit skips the provider entirely, so a test that asserts which
      # provider was asked needs a deterministic starting state.
      BotArmyLlm.CircuitBreaker.reset(:ollama)

      on_exit(fn ->
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
        BotArmyLlm.CircuitBreaker.reset(:ollama)
        if Process.whereis(:llm_model_type_spy), do: Process.unregister(:llm_model_type_spy)
      end)

      :ok
    end

    test "the type replaces the scored complexity at the router" do
      # A prompt the scorer would call :light ("What is the capital of France?")
      # must still be routed as :uncensored.
      assert {:error, :no_providers_available} =
               LlmClient.complete("What is the capital of France?", model_type: :uncensored)

      assert_received {:asked, :uncensored}
    end

    test "the type is accepted as a string, the way a payload carries it" do
      assert {:error, :no_providers_available} =
               LlmClient.complete("tell me more", model_type: "uncensored")

      assert_received {:asked, :uncensored}
    end

    test "a named node is still honoured alongside the type" do
      assert {:error, :no_providers_available} =
               LlmClient.complete("tell me more",
                 model_type: :uncensored,
                 ollama_node: "mini"
               )

      assert_received {:asked, :uncensored, "mini"}
    end

    test "a configured cloud chain is not consulted" do
      # The chain is where the promise is enforced: if :uncensored were ever
      # routed like a tier, the configured cloud provider would be tried and a
      # censored model could answer intimate content with a refusal.
      Application.put_env(:bot_army_llm, :provider_chain, [:blackbox, :openrouter])

      on_exit(fn -> Application.delete_env(:bot_army_llm, :provider_chain) end)

      with_env([{"BLACKBOX_API_KEY", "not-a-real-key"}], fn ->
        assert {:error, :no_providers_available} =
                 LlmClient.complete("tell me more", model_type: :uncensored)
      end)

      assert_received {:asked, :uncensored}
    end

    test "an unknown model_type is ignored, warned about, and scored as usual" do
      log =
        capture_log(fn ->
          assert {:error, :no_providers_available} =
                   LlmClient.complete("What is the capital of France?", model_type: "spicy")
        end)

      assert log =~ "unknown model_type"
      assert_received {:asked, :light}
    end

    test "omitting the type still scores the prompt" do
      assert {:error, :no_providers_available} =
               LlmClient.complete(
                 "Implement a binary search tree with insert and delete functions"
               )

      assert_received {:asked, :heavy}
    end
  end

  describe "the uncensored type is local by construction" do
    test "provider_chain(:uncensored) is ollama and nothing else" do
      assert LlmClient.provider_chain(:uncensored) == [:ollama]
    end

    test "a configured cloud chain cannot be reached by an uncensored request" do
      Application.put_env(:bot_army_llm, :provider_chain, [:blackbox, :openrouter])

      on_exit(fn -> Application.delete_env(:bot_army_llm, :provider_chain) end)

      assert LlmClient.provider_chain(:uncensored) == [:ollama]
      refute :blackbox in LlmClient.provider_chain(:uncensored)
      refute :openrouter in LlmClient.provider_chain(:uncensored)

      # The same configuration *is* honoured for a normal tier, so the assertion
      # above is about the type, not about the env var being ignored.
      assert :blackbox in LlmClient.provider_chain(:heavy)
    end
  end

  describe "Consumer.chat_opts/2 passthrough" do
    test "carries the model type through as an atom" do
      opts = Consumer.chat_opts(%{"model_type" => "uncensored"}, "urgent")
      assert Keyword.fetch!(opts, :model_type) == :uncensored
    end

    test "carries model and ollama_node (the earlier passthrough fix, pinned)" do
      opts =
        Consumer.chat_opts(%{"model" => "some-model", "ollama_node" => "mini"}, "interactive")

      assert Keyword.fetch!(opts, :model) == "some-model"
      assert Keyword.fetch!(opts, :ollama_node) == "mini"
    end

    test "an absent model type adds no option at all" do
      refute Keyword.has_key?(Consumer.chat_opts(%{}, "urgent"), :model_type)
      refute Keyword.has_key?(Consumer.chat_opts(%{"model_type" => ""}, "urgent"), :model_type)
    end

    test "an unknown model type is dropped with a warning, never converted to an atom" do
      log = capture_log(fn -> assert Consumer.chat_opts(%{"model_type" => "spicy"}, "urgent") end)

      opts = Consumer.chat_opts(%{"model_type" => "spicy"}, "urgent")

      refute Keyword.has_key?(opts, :model_type)
      assert log =~ "unknown model_type"
      assert_raise ArgumentError, fn -> String.to_existing_atom("spicy") end
    end

    test "lane defaults survive a model type request" do
      opts = Consumer.chat_opts(%{"model_type" => "uncensored"}, "background")

      assert Keyword.fetch!(opts, :model_type) == :uncensored
      assert Keyword.fetch!(opts, :allow_cloud_when_sensitive) == true
    end
  end

  describe "Consumer.chat_payload/1 unwraps the envelope" do
    # The decoder hands the consumer the WHOLE envelope, with the caller's fields
    # nested under "payload". Reading them at the top level yields an empty prompt
    # and drops the routing opts — and still returns a fluent answer, so nothing
    # points at the plumbing. Pinned here because the failure is invisible.
    test "a decoded envelope yields the nested payload" do
      envelope = %{
        "event_id" => "e-1",
        "event" => "wife_care.narration.requested",
        "schema_version" => "1.0",
        "timestamp" => "2026-09-21T13:00:00Z",
        "source" => "wife_care_bot",
        "source_node" => "wife_care_bot@mini",
        "triggered_by" => "wife_care_bot.narrator",
        "payload" => %{
          "prompt_context" => %{"prompt" => "say BANANA"},
          "model_type" => "uncensored"
        }
      }

      payload = Consumer.chat_payload(envelope)

      assert payload["prompt_context"]["prompt"] == "say BANANA"
      assert payload["model_type"] == "uncensored"
    end

    test "a bare payload passes through unchanged" do
      bare = %{"prompt_context" => %{"prompt" => "say BANANA"}, "model_type" => "uncensored"}

      assert Consumer.chat_payload(bare) == bare
    end

    test "the bridge's doubled envelope still resolves to the nested payload" do
      # The bridge mirrors system/messages/request_id at the top level, which is
      # precisely why this bug stayed hidden. Both levels are the same values, so
      # unwrapping keeps the reply correlated by request_id.
      envelope = %{
        "event" => "llm.request.chat",
        "payload" => %{"request_id" => "r-1", "messages" => [%{"role" => "user"}]},
        "request_id" => "r-1",
        "messages" => [%{"role" => "user"}]
      }

      assert Consumer.chat_payload(envelope)["request_id"] == "r-1"
    end

    test "a non-map payload does not shadow the message" do
      assert Consumer.chat_payload(%{"payload" => "not-a-map", "model_type" => "uncensored"})[
               "model_type"
             ] == "uncensored"

      assert Consumer.chat_payload("junk") == %{}
    end

    test "an envelope's routing controls survive the unwrap into provider opts" do
      envelope = %{
        "event" => "llm.request.chat",
        "payload" => %{
          "model_type" => "uncensored",
          "ollama_node" => "mini",
          "model" => "explicit-model"
        }
      }

      opts = Consumer.chat_payload(envelope) |> Consumer.chat_opts("interactive")

      assert Keyword.fetch!(opts, :model_type) == :uncensored
      assert Keyword.fetch!(opts, :ollama_node) == "mini"
      assert Keyword.fetch!(opts, :model) == "explicit-model"
    end
  end

  defp with_env(env_vars, func) do
    old_values = Enum.map(env_vars, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(env_vars, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      func.()
    after
      Enum.each(old_values, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
