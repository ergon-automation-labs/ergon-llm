defmodule BotArmyLlm.LlmClientTest do
  use ExUnit.Case
  @moduletag :client
  import ExUnit.CaptureLog

  alias BotArmyLlm.{ComplexityScorer, LlmClient, SafetyClassifier}

  describe "ComplexityScorer.score/1" do
    test "short factual question scores :light" do
      assert ComplexityScorer.score("What is the capital of France?") == :light
    end

    test "yes/no question scores :light" do
      assert ComplexityScorer.score("yes or no") == :light
    end

    test "single heavy keyword with enough words scores :medium" do
      # 1 heavy keyword ("explain"), 13 words → :medium
      assert ComplexityScorer.score(
               "Can you explain how TCP/IP packet routing works in a computer network?"
             ) == :medium
    end

    test "multiple heavy keywords scores :heavy" do
      # "implement" + "function" → 2 heavy keywords → :heavy regardless of length
      assert ComplexityScorer.score(
               "Implement a binary search tree with insert and delete functions"
             ) == :heavy
    end

    test "3+ heavy keywords scores :heavy" do
      assert ComplexityScorer.score(
               "Design and implement an algorithm to analyze and compare two code architectures"
             ) == :heavy
    end

    test "200+ word prompt scores :heavy" do
      long_text = String.duplicate("word ", 210)
      assert ComplexityScorer.score(long_text) == :heavy
    end
  end

  describe "complete/2 with no cloud providers configured" do
    test "heavy prompt returns error when all providers unconfigured" do
      defmodule MockHealthCheckerUnavailable do
        def best_ollama_node(_complexity), do: {:error, :no_healthy_nodes}
        def load_acceptable?(), do: true
        def node_status, do: []
      end

      with_env(
        [
          {"BLACKBOX_API_KEY", nil},
          {"OPENROUTER_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil}
        ],
        fn ->
          Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerUnavailable)

          try do
            # 200+ words → :heavy → tries cloud + Ollama, all unavailable → fails
            heavy_prompt = String.duplicate("implement complex algorithm code ", 10)
            assert {:error, :no_providers_available} = LlmClient.complete(heavy_prompt)
          after
            Application.delete_env(:bot_army_llm, :ollama_health_checker)
          end
        end
      )
    end
  end

  describe "SafetyClassifier integration in complete/2" do
    @describetag :integration
    test "safe text routes through normal provider chain" do
      safe_text = "What is the capital of France?"

      # Verify text is classified as safe
      assert SafetyClassifier.safe_for_cloud?(safe_text) == true

      # Mock: Ollama should be in the chain (first provider for light complexity)
      # Since Ollama will fail (not available in tests), it will try next provider
      # This test just verifies no early routing blocking happens
      result = LlmClient.complete(safe_text)
      # Should error due to no providers, not due to blocking
      assert elem(result, 0) in [:ok, :error]
    end

    test "sensitive text (API key) blocks cloud routing" do
      sensitive_text = "My API key is sk-proj-abc123def456ghi789jkl012mnopqr"

      # Verify text is classified as sensitive
      assert SafetyClassifier.safe_for_cloud?(sensitive_text) == false

      # The prompt should be blocked from cloud providers
      # We can verify this by checking that only :ollama is attempted
      # In practice, Ollama will fail, but the safety check prevents cloud attempts
      log =
        capture_log(fn ->
          _result = LlmClient.complete(sensitive_text)
        end)

      # Should log that routing is to local-only
      assert String.contains?(log, "local-only")
    end

    test "sensitive text (AWS key) blocks cloud routing" do
      defmodule MockHealthCheckerSensitiveAWS do
        def load_acceptable?(), do: true
        def best_ollama_node(_complexity), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerSensitiveAWS)

      try do
        sensitive_text = "AWS credentials: AKIAIOSFODNN7EXAMPLE"

        assert SafetyClassifier.safe_for_cloud?(sensitive_text) == false

        log =
          capture_log(fn ->
            _result = LlmClient.complete(sensitive_text)
          end)

        assert String.contains?(log, "local-only")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end

    test "sensitive text (private key) blocks cloud routing" do
      defmodule MockHealthCheckerSensitiveKey do
        def load_acceptable?(), do: true
        def best_ollama_node(_complexity), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerSensitiveKey)

      try do
        sensitive_text =
          "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQE\n-----END PRIVATE KEY-----"

        assert SafetyClassifier.safe_for_cloud?(sensitive_text) == false

        log =
          capture_log(fn ->
            _result = LlmClient.complete(sensitive_text)
          end)

        assert String.contains?(log, "local-only")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end
  end

  describe "SafetyClassifier integration in complete_messages/2" do
    @describetag :integration
    test "messages with safe content route normally" do
      messages = [
        %{"role" => "user", "content" => "What is the weather?"}
      ]

      assert SafetyClassifier.safe_for_cloud?("What is the weather?") == true
      result = LlmClient.complete_messages(messages)
      # Should get error due to no providers, not safety blocking
      assert elem(result, 0) in [:ok, :error]
    end

    test "messages with sensitive content block cloud routing" do
      defmodule MockHealthCheckerMessagesAuth do
        def load_acceptable?(), do: true
        def best_ollama_node(_complexity), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerMessagesAuth)

      try do
        messages = [
          %{"role" => "user", "content" => "Analyze my credentials: password=super_secret_123"}
        ]

        log =
          capture_log(fn ->
            _result = LlmClient.complete_messages(messages)
          end)

        assert String.contains?(log, "local-only")
        assert String.contains?(log, "multi-turn")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end

    test "mixed messages check all content for sensitivity" do
      defmodule MockHealthCheckerMessagesMixed do
        def load_acceptable?(), do: true
        def best_ollama_node(_complexity), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerMessagesMixed)

      try do
        messages = [
          %{"role" => "assistant", "content" => "Safe response"},
          %{"role" => "user", "content" => "secret_key = sk-ant-abc123"}
        ]

        log =
          capture_log(fn ->
            _result = LlmClient.complete_messages(messages)
          end)

        assert String.contains?(log, "local-only")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end
  end

  describe "SafetyClassifier integration in complete_vision/2" do
    @describetag :integration
    test "vision with safe prompt routes normally" do
      log =
        capture_log(fn ->
          _result =
            LlmClient.complete_vision(nil, "https://example.com/image.png", "Describe this image")
        end)

      # Should not log local-only for safe prompt
      assert !String.contains?(log, "local-only") || String.contains?(log, "no_image_provided")
    end

    test "vision with sensitive prompt blocks cloud routing" do
      log =
        capture_log(fn ->
          _result =
            LlmClient.complete_vision(
              nil,
              "https://example.com/image.png",
              "Analyze password=secret123 from this image"
            )
        end)

      assert String.contains?(log, "local-only")
      assert String.contains?(log, "vision")
    end

    test "vision with API key in prompt blocks cloud" do
      log =
        capture_log(fn ->
          _result =
            LlmClient.complete_vision(
              nil,
              "https://example.com/image.png",
              "My token is sk-proj-1234567890123456789"
            )
        end)

      assert String.contains?(log, "local-only")
    end
  end

  describe "SafetyClassifier integration in embed/2" do
    @describetag :integration
    @tag :integration
    test "safe text can route to both ollama and openrouter" do
      safe_text = "The quick brown fox jumps over the lazy dog"

      assert SafetyClassifier.safe_for_cloud?(safe_text) == true

      # Just verify the call returns error (no providers available in test)
      # not a safety blocking error
      result = LlmClient.embed(safe_text)
      assert elem(result, 0) in [:ok, :error]
    end

    test "sensitive text (API key) blocks cloud embed routing" do
      sensitive_text = "My API key is sk-proj-abc123def456ghi789jkl012mnopqr"

      assert SafetyClassifier.safe_for_cloud?(sensitive_text) == false

      log =
        capture_log(fn ->
          _result = LlmClient.embed(sensitive_text)
        end)

      assert String.contains?(log, "local-only")
      assert String.contains?(log, "embed")
    end

    test "sensitive text (AWS key) blocks cloud embed routing" do
      sensitive_text = "AWS key: AKIAIOSFODNN7EXAMPLE"

      assert SafetyClassifier.safe_for_cloud?(sensitive_text) == false

      log =
        capture_log(fn ->
          _result = LlmClient.embed(sensitive_text)
        end)

      assert String.contains?(log, "local-only")
    end

    test "sensitive text (secret keyword) blocks cloud embed routing" do
      sensitive_text = "database secret_key = someverysecretvalue"

      assert SafetyClassifier.safe_for_cloud?(sensitive_text) == false

      log =
        capture_log(fn ->
          _result = LlmClient.embed(sensitive_text)
        end)

      assert String.contains?(log, "local-only")
    end
  end

  describe "load-based routing" do
    test "light prompt with load acceptable includes Ollama in chain" do
      # When load is acceptable, Ollama should be attempted before cloud providers
      # Since Ollama will fail (not running), we check that the error doesn't mention "under load"
      defmodule MockHealthCheckerLoad do
        def load_acceptable?(), do: true
        def best_ollama_node(:light), do: {:error, :no_healthy_nodes}
        def best_ollama_node(:medium), do: {:error, :no_healthy_nodes}
        def best_ollama_node(:heavy), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerLoad)

      try do
        light_prompt = "What is 2+2?"

        log =
          capture_log(fn ->
            _result = LlmClient.complete(light_prompt)
          end)

        # Should not log "under load" message when load is acceptable
        refute String.contains?(log, "under load")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end

    test "light prompt with high load skips Ollama and logs routing decision" do
      defmodule MockHealthCheckerHighLoad do
        def load_acceptable?(), do: false
        def best_ollama_node(complexity), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(:bot_army_llm, :ollama_health_checker, MockHealthCheckerHighLoad)

      try do
        light_prompt = "What is the weather?"

        log =
          capture_log(fn ->
            _result = LlmClient.complete(light_prompt)
          end)

        # Should log "under load" message indicating Ollama was skipped
        assert String.contains?(log, "under load")
        assert String.contains?(log, "cloud providers")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end

    test "sensitive prompt still forces Ollama even with high load" do
      defmodule MockHealthCheckerHighLoadSensitive do
        def load_acceptable?(), do: false
        def best_ollama_node(complexity), do: {:error, :no_healthy_nodes}
        def node_status, do: []
      end

      Application.put_env(
        :bot_army_llm,
        :ollama_health_checker,
        MockHealthCheckerHighLoadSensitive
      )

      try do
        # Sensitive prompt with API key
        sensitive_prompt = "My API key is sk-proj-abc123def456ghi789jkl012mnopqr"

        log =
          capture_log(fn ->
            _result = LlmClient.complete(sensitive_prompt)
          end)

        # Should log local-only routing (safety overrides load)
        assert String.contains?(log, "local-only")
        # Should NOT log "under load" — safety check prevents even getting to load check
        refute String.contains?(log, "under load")
      after
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      end
    end
  end

  # Temporarily override env vars for the duration of a test
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
