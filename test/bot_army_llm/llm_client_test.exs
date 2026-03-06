defmodule BotArmyLlm.LlmClientTest do
  use ExUnit.Case

  describe "complete/2" do
    test "returns error when no providers are available" do
      # When all providers are unavailable (no env vars set, no services running)
      # This test may fail if local Ollama is actually running
      with_env([
        {"OLLAMA_URL", "http://nonexistent:11434"},
        {"OLLAMA_MINI_URL", nil},
        {"BLACKBOX_API_KEY", nil},
        {"ANTHROPIC_API_KEY", nil}
      ]) do
        {:error, :no_providers_available} = BotArmyLlm.LlmClient.complete("test prompt")
      end
    end

    test "returns ok when Ollama is available" do
      # Mock HTTPoison to simulate Ollama response
      {:ok, _pid} = start_supervised({ExUnit.Callbacks, []})

      with_mock(HTTPoison, [:passthrough],
        post: fn _url, _body, _headers ->
          {:ok,
           %HTTPoison.Response{
             status_code: 200,
             body:
               Jason.encode!(%{
                 "message" => %{"content" => "This is a test response"}
               })
           }}
        end
      ) do
        assert {:ok, result} = BotArmyLlm.LlmClient.complete("test prompt")
        assert result[:completion] == "This is a test response"
        assert result[:model_used] == "llama3.2"
        assert is_integer(result[:latency_ms])
      end
    end

    test "resolves model based on North Star conventions" do
      with_mock(HTTPoison, [:passthrough],
        post: fn _url, body, _headers ->
          case Jason.decode(body) do
            {:ok, payload} ->
              model = Map.get(payload, "model")

              {:ok,
               %HTTPoison.Response{
                 status_code: 200,
                 body: Jason.encode!(%{"message" => %{"content" => "response"}})
               }}

            {:error, _} ->
              {:error, :invalid_json}
          end
        end
      ) do
        with_env([{"ANTHROPIC_API_KEY", "test_key"}]) do
          {:ok, result} = BotArmyLlm.LlmClient.complete("test", model: "fast")
          assert result[:model_used] == "claude-haiku-4-5-20251001"

          {:ok, result} = BotArmyLlm.LlmClient.complete("test", model: "powerful")
          assert result[:model_used] == "claude-sonnet-4-6"
        end
      end
    end
  end

  # Helper to set env vars for test
  defp with_env(env_vars, func) do
    old_values = Enum.map(env_vars, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(env_vars, fn {key, value} ->
      if value, do: System.put_env(key, value), else: System.delete_env(key)
    end)

    try do
      func.()
    after
      Enum.each(old_values, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end
  end

  defp with_env(env_vars, test_func) when is_function(test_func, 0) do
    old_values = Enum.map(env_vars, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(env_vars, fn {key, value} ->
      if value, do: System.put_env(key, value), else: System.delete_env(key)
    end)

    try do
      test_func.()
    after
      Enum.each(old_values, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end
  end
end
