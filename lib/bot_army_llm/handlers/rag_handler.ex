defmodule BotArmyLlm.Handlers.RAGHandler do
  @moduledoc """
  Handles RAG (Retrieval Augmented Generation) events for the LLM bot.

  This module processes:
  - `llm.rag.index` - Index a document with its embedding
  - `llm.rag.search` - Search for semantically similar documents
  - `llm.rag.delete` - Delete documents by ID
  """

  require Logger
  alias BotArmyLlm.NATS.Publisher
  alias BotArmyLlm.{EmbeddingConfig, EventBuilder}

  defp vector_store do
    Application.get_env(:bot_army_llm, :vector_store, BotArmyLlm.VectorStore)
  end

  @doc """
  Handle RAG index request.

  Expected payload structure:
  ```
  {
    "document_id": string (required),
    "document_type": string (required),
    "source": string (required),
    "content": string (required),
    "metadata": map (optional),
    "model": string (optional; if omitted, Ollama uses `BOT_ARMY_LLM_EMBED_DEFAULT_MODEL` and OpenRouter uses `BOT_ARMY_LLM_OPENROUTER_EMBED_DEFAULT_MODEL`; if set, both providers use this id)
  }
  ```

  Publishes:
  - `llm.rag.indexed` on success
  - `llm.error` on failure
  """
  def handle_index(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_index_payload(payload) do
      :ok ->
        process_index(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid RAG index payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid RAG index data", tenant_id, user_id)
    end
  end

  @doc """
  Handle RAG search request.

  Expected payload structure:
  ```
  {
    "query": string (required),
    "limit": integer (optional, default: 5),
    "document_type": string (optional),
    "source": string (optional),
    "min_similarity": float (optional, default: 0.0),
    "model": string (optional; same semantics as index — per-provider defaults or one explicit id)
  }
  ```

  Publishes:
  - `llm.rag.search.result` with matching documents
  - `llm.error` on failure
  """
  def handle_search(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_search_payload(payload) do
      :ok ->
        process_search(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid RAG search payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid RAG search data", tenant_id, user_id)
    end
  end

  @doc """
  Handle RAG delete request.

  Expected payload structure:
  ```
  {
    "document_id": string (required)
  }
  ```

  Publishes:
  - `llm.rag.deleted` on success
  - `llm.error` on failure
  """
  def handle_delete(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_delete_payload(payload) do
      :ok ->
        process_delete(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid RAG delete payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid RAG delete data", tenant_id, user_id)
    end
  end

  # Private functions

  defp validate_index_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "document_id"),
         :ok <- require_field(payload, "document_type"),
         :ok <- require_field(payload, "source") do
      require_field(payload, "content")
    end
  end

  defp validate_index_payload(_), do: {:error, :invalid_payload}

  defp validate_search_payload(payload) when is_map(payload) do
    require_field(payload, "query")
  end

  defp validate_search_payload(_), do: {:error, :invalid_payload}

  defp validate_delete_payload(payload) when is_map(payload) do
    require_field(payload, "document_id")
  end

  defp validate_delete_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_index(payload, event_id, tenant_id, user_id) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
    model = EmbeddingConfig.optional_explicit_model(Map.get(payload, "model"))

    Logger.debug("Indexing document: #{payload["document_id"]}")

    case llm_client.embed(payload["content"], model) do
      {:ok, response} ->
        doc_map = %{
          "document_id" => payload["document_id"],
          "document_type" => payload["document_type"],
          "source" => payload["source"],
          "content" => payload["content"],
          "embedding" => response.embedding,
          "metadata" => Map.get(payload, "metadata")
        }

        case vector_store().index(doc_map) do
          {:ok, id} ->
            publish_indexed(id, payload["document_id"], event_id, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to index document: #{inspect(reason)}")
            publish_error(event_id, reason, "Failed to store embedding", tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.error("Embedding generation failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to generate embedding", tenant_id, user_id)
    end
  end

  defp process_search(payload, event_id, tenant_id, user_id) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
    query = payload["query"]
    model = EmbeddingConfig.optional_explicit_model(Map.get(payload, "model"))
    limit = Map.get(payload, "limit", 5)
    document_type = payload["document_type"]
    source = payload["source"]
    min_similarity = Map.get(payload, "min_similarity", 0.0)

    Logger.debug("Searching for: #{query}")

    case llm_client.embed(query, model) do
      {:ok, response} ->
        search_opts = [limit: limit, min_similarity: min_similarity]

        search_opts =
          if is_binary(document_type),
            do: Keyword.put(search_opts, :document_type, document_type),
            else: search_opts

        search_opts =
          if is_binary(source),
            do: Keyword.put(search_opts, :source, source),
            else: search_opts

        case vector_store().search(response.embedding, search_opts) do
          {:ok, results} ->
            publish_search_result(results, event_id, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Search failed: #{inspect(reason)}")
            publish_error(event_id, reason, "Search failed", tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.error("Query embedding generation failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to generate query embedding", tenant_id, user_id)
    end
  end

  defp process_delete(payload, event_id, tenant_id, user_id) do
    document_id = payload["document_id"]

    Logger.debug("Deleting document: #{document_id}")

    case vector_store().delete_by_document_id(document_id) do
      :ok ->
        publish_deleted(document_id, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.error("Delete failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to delete document", tenant_id, user_id)
    end
  end

  defp publish_indexed(id, document_id, triggered_by_event_id, tenant_id, user_id) do
    payload = %{
      "embedding_id" => id,
      "document_id" => document_id,
      "triggered_by_event_id" => triggered_by_event_id,
      "tenant_id" => tenant_id,
      "user_id" => user_id
    }

    event_data = EventBuilder.build("llm.rag.indexed", payload)

    case Publisher.publish(event_data) do
      :ok -> Logger.info("Published RAG indexed event")
      {:error, reason} -> Logger.error("Failed to publish indexed event: #{inspect(reason)}")
    end
  end

  defp publish_search_result(results, triggered_by_event_id, tenant_id, user_id) do
    payload = %{
      "results" => results,
      "count" => length(results),
      "triggered_by_event_id" => triggered_by_event_id,
      "tenant_id" => tenant_id,
      "user_id" => user_id
    }

    event_data = EventBuilder.build("llm.rag.search.result", payload)

    case Publisher.publish(event_data) do
      :ok -> Logger.info("Published RAG search result")
      {:error, reason} -> Logger.error("Failed to publish search result: #{inspect(reason)}")
    end
  end

  defp publish_deleted(document_id, triggered_by_event_id, tenant_id, user_id) do
    payload = %{
      "document_id" => document_id,
      "triggered_by_event_id" => triggered_by_event_id,
      "tenant_id" => tenant_id,
      "user_id" => user_id
    }

    event_data = EventBuilder.build("llm.rag.deleted", payload)

    case Publisher.publish(event_data) do
      :ok -> Logger.info("Published RAG deleted event")
      {:error, reason} -> Logger.error("Failed to publish deleted event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    error_event = %{
      "event" => "llm.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case Publisher.publish(error_event) do
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end
