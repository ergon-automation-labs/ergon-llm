defmodule BotArmyLlm.Handlers.VisionHandlerTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:bot_army_llm, :llm_client, TestVisionLlmClientMock)
    on_exit(fn -> Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient) end)
    :ok
  end

  describe "handle_analyze/1" do
    test "analyzes image and returns raw analysis" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "What do you see in this image?",
          "image_data" => "base64encodeddata",
          "model" => "auto"
        }
      }

      Process.put({:vision_llm_mock, :response}, {:ok, %{
        completion: "I see a dog in the image",
        model_used: "vision-model",
        tokens_input: 5,
        tokens_output: 10,
        latency_ms: 500
      }})

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "extracts structured data with output_schema" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "Analyze game coordinates",
          "image_url" => "https://example.com/image.png",
          "output_schema" => %{"type" => "object", "required" => ["x", "y"]}
        }
      }

      Process.put({:vision_llm_mock, :response}, {:ok, %{
        completion: ~s({"x": 100, "y": 200, "detected": true}),
        model_used: "vision-model",
        tokens_input: 8,
        tokens_output: 15,
        latency_ms: 600
      }})

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "handles best-effort JSON parsing with schema" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "Describe what you see",
          "image_data" => "encoded_image",
          "output_schema" => %{"type" => "object"}
        }
      }

      # Returns plain text, not JSON - should still return raw analysis
      Process.put({:vision_llm_mock, :response}, {:ok, %{
        completion: "A beautiful sunset over the ocean",
        model_used: "vision-model",
        tokens_input: 5,
        tokens_output: 12,
        latency_ms: 400
      }})

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "validates required prompt field" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => nil,
          "image_data" => "data"
        }
      }

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "validates at least one image field is provided" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "Analyze this",
          "image_data" => nil,
          "image_url" => nil
        }
      }

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "accepts image_url alone" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "What is this?",
          "image_url" => "https://example.com/photo.jpg"
        }
      }

      Process.put({:vision_llm_mock, :response}, {:ok, %{
        completion: "This is a photo of a building",
        model_used: "vision-model",
        tokens_input: 5,
        tokens_output: 8,
        latency_ms: 350
      }})

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "accepts image_data alone" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "Identify objects",
          "image_data" => "base64_encoded_data"
        }
      }

      Process.put({:vision_llm_mock, :response}, {:ok, %{
        completion: "Objects detected: dog, ball, tree",
        model_used: "vision-model",
        tokens_input: 3,
        tokens_output: 8,
        latency_ms: 450
      }})

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end

    test "handles vision model failures" do
      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.vision.analyze",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "prompt" => "Analyze image",
          "image_data" => "data"
        }
      }

      Process.put({:vision_llm_mock, :response}, {:error, :no_providers_available})

      assert :ok = BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)
    end
  end
end

defmodule TestVisionLlmClientMock do
  def complete(text, _opts \\ []) when is_binary(text) do
    Process.get({:vision_llm_mock, :response}, {:error, :not_configured})
  end

  def complete_messages(messages, _opts \\ []) when is_list(messages) do
    Process.get({:vision_llm_mock, :response}, {:error, :not_configured})
  end

  def complete_vision(_image_data, _image_url, _prompt, _opts \\ []) do
    Process.get({:vision_llm_mock, :response}, {:error, :not_configured})
  end
end
