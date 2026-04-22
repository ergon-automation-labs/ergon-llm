defmodule BotArmyLlm.RAGHandlerTestLlmClientMock do
  @moduledoc "Mock LLM client for RAG handler tests"

  def embed(text, _model \\ nil) when is_binary(text) do
    # Return the configured response or default
    Process.get(
      {:rag_handler_test, :embed_response},
      {:ok,
       %{
         embedding: List.duplicate(0.1, 768),
         model_used: "nomic-embed-text",
         tokens_input: 10,
         tokens_output: 0,
         latency_ms: 50
       }}
    )
  end
end

defmodule BotArmyLlm.RAGHandlerTestVectorStoreMock do
  @moduledoc "Mock VectorStore for RAG handler tests"

  def index(_doc_map) do
    {:ok, UUID.uuid4()}
  end

  def search(_query_vector, _opts \\ []) do
    {:ok,
     [
       %{
         document_id: "doc-1",
         document_type: "job_description",
         source: "bot_army_job",
         content: "Senior Elixir engineer",
         similarity: 0.95
       }
     ]}
  end

  def delete_by_document_id(_document_id) do
    :ok
  end

  def list_by_type(_document_type) do
    {:ok, []}
  end
end

defmodule BotArmyLlm.Handlers.RAGHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :handlers

  alias BotArmyLlm.Handlers.RAGHandler

  setup do
    # Set the mock LLM client in Application config
    Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.RAGHandlerTestLlmClientMock)
    Application.put_env(:bot_army_llm, :vector_store, BotArmyLlm.RAGHandlerTestVectorStoreMock)

    on_exit(fn ->
      # Restore the real clients after the test
      Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
      Application.put_env(:bot_army_llm, :vector_store, BotArmyLlm.VectorStore)
    end)

    :ok
  end

  describe "handle_index/1" do
    test "successfully indexes a document with embedding" do
      message = valid_index_message()

      # Configure mock to return an embedding
      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_index(message)
    end

    test "validates required document_id field" do
      message = valid_index_message() |> put_in(["payload", "document_id"], nil)

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_index(message)
    end

    test "validates required document_type field" do
      message = valid_index_message() |> put_in(["payload", "document_type"], nil)

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_index(message)
    end

    test "validates required content field" do
      message = valid_index_message() |> put_in(["payload", "content"], nil)

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_index(message)
    end

    test "handles LLM embedding failures gracefully" do
      message = valid_index_message()

      # Configure mock to return an error
      Process.put({:rag_handler_test, :embed_response}, {:error, :rate_limited})

      assert :ok = RAGHandler.handle_index(message)
    end

    test "uses custom model if provided" do
      message = valid_index_message() |> put_in(["payload", "model"], "custom-embed")

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "custom-embed",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_index(message)
    end
  end

  describe "handle_search/1" do
    test "successfully searches for similar documents" do
      message = valid_search_message()

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_search(message)
    end

    test "validates required query field" do
      message = valid_search_message() |> put_in(["payload", "query"], nil)

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_search(message)
    end

    test "handles query embedding failures" do
      message = valid_search_message()

      Process.put({:rag_handler_test, :embed_response}, {:error, :timeout})

      assert :ok = RAGHandler.handle_search(message)
    end

    test "accepts optional limit parameter" do
      message = valid_search_message() |> put_in(["payload", "limit"], 10)

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_search(message)
    end

    test "accepts optional document_type filter" do
      message = valid_search_message() |> put_in(["payload", "document_type"], "job_description")

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_search(message)
    end

    test "accepts optional source filter" do
      message = valid_search_message() |> put_in(["payload", "source"], "bot_army_job")

      Process.put(
        {:rag_handler_test, :embed_response},
        {:ok,
         %{
           embedding: List.duplicate(0.1, 768),
           model_used: "nomic-embed-text",
           tokens_input: 10,
           tokens_output: 0,
           latency_ms: 50
         }}
      )

      assert :ok = RAGHandler.handle_search(message)
    end
  end

  describe "handle_delete/1" do
    test "successfully deletes a document" do
      message = valid_delete_message()

      assert :ok = RAGHandler.handle_delete(message)
    end

    test "validates required document_id field" do
      message = valid_delete_message() |> put_in(["payload", "document_id"], nil)

      assert :ok = RAGHandler.handle_delete(message)
    end

    test "publishes deleted event" do
      message = valid_delete_message()

      assert :ok = RAGHandler.handle_delete(message)
    end
  end

  # Helper functions

  defp valid_index_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.rag.index",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "payload" => %{
        "document_id" => "job-123",
        "document_type" => "job_description",
        "source" => "bot_army_job_applications",
        "content" => "Senior Elixir engineer needed for distributed systems work",
        "metadata" => %{"company" => "Acme Corp", "location" => "remote"}
      }
    }
  end

  defp valid_search_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.rag.search",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "payload" => %{
        "query" => "Elixir engineer position",
        "limit" => 5,
        "min_similarity" => 0.0
      }
    }
  end

  defp valid_delete_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.rag.delete",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "payload" => %{
        "document_id" => "job-123"
      }
    }
  end
end
