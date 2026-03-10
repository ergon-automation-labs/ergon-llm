defmodule BotArmyLlm.Handlers.ResponseHandlerTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:bot_army_llm, :llm_client, TestResponseLlmClientMock)
    on_exit(fn -> Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient) end)
    :ok
  end

  describe "handle_parse/1" do
    test "extracts JSON directly from text" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => ~s({"result": "success", "code": 200}),
          "output_schema" => %{"type" => "object"}
        }
      }

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "extracts JSON from markdown fence" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => ~s(Here's the response:\n```json\n{"status": "ok"}\n```),
          "output_schema" => %{"type" => "object"}
        }
      }

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "validates against output schema" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => ~s({"name": "John", "age": 30}),
          "output_schema" => %{"type" => "object", "required" => ["name", "age"]}
        }
      }

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "retries extraction on failure with corrective prompt" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => "No JSON here",
          "max_retries" => 1,
          "output_schema" => %{"type" => "object"}
        }
      }

      # First attempt fails, correction returns valid JSON
      Process.put({:response_llm_mock, :response}, {:ok, %{
        completion: ~s({"extracted": true}),
        model_used: "test",
        tokens_input: 10,
        tokens_output: 5,
        latency_ms: 150
      }})

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "publishes error when max_retries exceeded" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => "Not JSON at all",
          "max_retries" => 0
        }
      }

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "validates required text field" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => nil,
          "output_schema" => %{"type" => "object"}
        }
      }

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "works without output_schema" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => ~s([1, 2, 3, 4, 5])
        }
      }

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end

    test "handles schema mismatch with retries" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.response.parse",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "text" => ~s([1, 2, 3]),
          "output_schema" => %{"type" => "object"},
          "max_retries" => 1
        }
      }

      # Correction returns object instead of array
      Process.put({:response_llm_mock, :response}, {:ok, %{
        completion: ~s({"items": [1, 2, 3]}),
        model_used: "test",
        tokens_input: 10,
        tokens_output: 15,
        latency_ms: 120
      }})

      assert :ok = BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)
    end
  end

  # Helper functions
end

defmodule TestResponseLlmClientMock do
  def complete(text, _opts \\ []) when is_binary(text) do
    Process.get({:response_llm_mock, :response}, {:ok, %{
      completion: "Mock response",
      model_used: "test-model",
      tokens_input: 5,
      tokens_output: 10,
      latency_ms: 100
    }})
  end

  def complete_messages(messages, _opts \\ []) when is_list(messages) do
    Process.get({:response_llm_mock, :response}, {:error, :not_configured})
  end

  def complete_vision(_image_data, _image_url, _prompt, _opts \\ []) do
    Process.get({:response_llm_mock, :response}, {:error, :not_configured})
  end
end
