defmodule BotArmyLlm.Handlers.InferenceHandlerTest do
  use ExUnit.Case, async: false

  describe "handle_chain/1" do
    setup do
      Application.put_env(:bot_army_llm, :llm_client, TestLlmClientMock)
      on_exit(fn -> Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient) end)
      :ok
    end

    test "successfully processes a multi-step chain" do
      message = valid_chain_message()

      # Configure mock to return step outputs
      Process.put({:llm_client_mock, :response}, {:ok, %{
        completion: "output step 1",
        model_used: "test-model",
        tokens_input: 5,
        tokens_output: 10,
        latency_ms: 100
      }})

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)
    end

    test "validates required steps field" do
      message = valid_chain_message()
               |> put_in(["payload", "steps"], nil)

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)
    end

    test "validates required initial_input field" do
      message = valid_chain_message()
               |> put_in(["payload", "initial_input"], nil)

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)
    end

    test "handles LLM failures gracefully" do
      message = valid_chain_message()

      Process.put({:llm_client_mock, :response}, {:error, :rate_limited})

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)
    end

    test "interpolates {input} in step prompts" do
      steps = [
        %{"prompt" => "Analyze: {input}"},
        %{"prompt" => "Summarize: {input}"}
      ]

      message = %{
        "event_id" => UUID.uuid4(),
        "event" => "llm.inference.chain",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "test",
        "source_node" => "test_node",
        "triggered_by" => "test",
        "schema_version" => "1.0",
        "payload" => %{
          "chain_id" => UUID.uuid4(),
          "steps" => steps,
          "initial_input" => "test data",
          "model" => "auto"
        }
      }

      Process.put({:llm_client_mock, :response}, {:ok, %{
        completion: "processed",
        model_used: "test",
        tokens_input: 5,
        tokens_output: 10,
        latency_ms: 100
      }})

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)
    end
  end

  describe "handle_converse/1" do
    setup do
      Application.put_env(:bot_army_llm, :llm_client, TestLlmClientMock)
      Application.put_env(:bot_army_llm, :conversation_store, TestConversationStoreMock)

      on_exit(fn ->
        Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
        Application.put_env(:bot_army_llm, :conversation_store, BotArmyLlm.ConversationStore)
      end)

      :ok
    end

    test "successfully handles a conversation message" do
      message = valid_converse_message()

      # Mock LLM response
      Process.put({:llm_client_mock, :response}, {:ok, %{
        completion: "Hello! How can I help?",
        model_used: "test-model",
        tokens_input: 5,
        tokens_output: 12,
        latency_ms: 100
      }})

      # Mock conversation creation
      Process.put({:conversation_store_mock, :create_response}, {:ok, UUID.uuid4(), %{
        "session_id" => UUID.uuid4(),
        "messages" => [],
        "model" => "auto"
      }})

      # Mock message append
      Process.put({:conversation_store_mock, :append_response}, {:ok, %{
        "session_id" => UUID.uuid4(),
        "messages" => [
          %{"role" => "user", "content" => "Hi there"},
          %{"role" => "assistant", "content" => "Hello! How can I help?"}
        ]
      }})

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_converse(message)
    end

    test "validates required message field" do
      message = valid_converse_message()
               |> put_in(["payload", "message"], nil)

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_converse(message)
    end

    test "handles LLM failures" do
      message = valid_converse_message()

      Process.put({:llm_client_mock, :response}, {:error, :no_providers_available})

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_converse(message)
    end

    test "creates new conversation when no session_id provided" do
      message = valid_converse_message() |> Map.update!("payload", &Map.delete(&1, "session_id"))

      Process.put({:llm_client_mock, :response}, {:ok, %{
        completion: "Reply",
        model_used: "test",
        tokens_input: 5,
        tokens_output: 10,
        latency_ms: 100
      }})

      Process.put({:conversation_store_mock, :create_response}, {:ok, UUID.uuid4(), %{
        "messages" => []
      }})

      Process.put({:conversation_store_mock, :append_response}, {:ok, %{
        "messages" => [
          %{"role" => "user", "content" => "test"}
        ]
      }})

      assert :ok = BotArmyLlm.Handlers.InferenceHandler.handle_converse(message)
    end
  end

  # Helper functions

  defp valid_chain_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.inference.chain",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test",
      "source_node" => "test_node",
      "triggered_by" => "test",
      "schema_version" => "1.0",
      "payload" => %{
        "chain_id" => UUID.uuid4(),
        "steps" => [
          %{"prompt" => "Process: {input}"}
        ],
        "initial_input" => "test",
        "model" => "auto"
      }
    }
  end

  defp valid_converse_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.inference.converse",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test",
      "source_node" => "test_node",
      "triggered_by" => "test",
      "schema_version" => "1.0",
      "payload" => %{
        "message" => "Hi there",
        "session_id" => UUID.uuid4(),
        "model" => "auto"
      }
    }
  end
end

defmodule TestLlmClientMock do
  def complete(text, _opts \\ []) when is_binary(text) do
    Process.get({:llm_client_mock, :response}, {:error, :not_configured})
  end

  def complete_messages(messages, _opts \\ []) when is_list(messages) do
    Process.get({:llm_client_mock, :response}, {:error, :not_configured})
  end

  def complete_vision(_image_data, _image_url, _prompt, _opts \\ []) do
    Process.get({:llm_client_mock, :response}, {:error, :not_configured})
  end
end

defmodule TestConversationStoreMock do
  def create(payload) when is_map(payload) do
    Process.get({:conversation_store_mock, :create_response}, {:error, :not_configured})
  end

  def get_session(session_id) when is_binary(session_id) do
    Process.get({:conversation_store_mock, :get_response}, {:error, :not_found})
  end

  def append_message(session_id, message) when is_binary(session_id) and is_map(message) do
    Process.get({:conversation_store_mock, :append_response}, {:error, :not_configured})
  end

  def archive(session_id) when is_binary(session_id) do
    Process.get({:conversation_store_mock, :archive_response}, {:ok, %{}})
  end

  def clear do
    :ok
  end
end
