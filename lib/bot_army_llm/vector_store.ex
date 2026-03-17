defmodule BotArmyLlm.VectorStore do
  @moduledoc """
  Vector store for RAG (Retrieval Augmented Generation).

  Manages embeddings in PostgreSQL with pgvector, providing
  document indexing and semantic search capabilities.

  All operations are stateless and hit the database directly.
  """

  use GenServer
  require Logger

  alias BotArmyLlm.Schemas.Embedding
  import Ecto.Query

  defp repo do
    Application.get_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
  end

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Index a document with its embedding vector.

  Args:
    - doc_map: %{
        "document_id" => string (required),
        "document_type" => string (required),
        "source" => string (required),
        "content" => string (required),
        "embedding" => vector (required),
        "metadata" => map (optional)
      }

  Returns: {:ok, embedding_id} | {:error, reason}
  """
  def index(doc_map) when is_map(doc_map) do
    case Embedding.changeset(doc_map) |> repo().insert() do
      {:ok, embedding} ->
        Logger.info("Indexed document: #{doc_map["document_id"]}")
        {:ok, embedding.id}

      {:error, reason} ->
        Logger.error("Failed to index document: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def index(_), do: {:error, :invalid_document}

  @doc """
  Search for documents similar to a query vector.

  Args:
    - query_vector: vector (768-dimensional for nomic-embed-text)
    - opts: [
        limit: integer (default 5),
        document_type: string (optional),
        source: string (optional),
        min_similarity: float (default 0.0)
      ]

  Returns: {:ok, [result_map]} | {:error, reason}

  Each result is: %{
    document_id: string,
    document_type: string,
    source: string,
    content: string,
    similarity: float (0.0 to 1.0)
  }
  """
  def search(query_vector, opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 5)
    document_type = Keyword.get(opts, :document_type)
    source = Keyword.get(opts, :source)
    min_similarity = Keyword.get(opts, :min_similarity, 0.0)

    query =
      from(e in Embedding,
        select: %{
          document_id: e.document_id,
          document_type: e.document_type,
          source: e.source,
          content: e.content,
          similarity: fragment("1 - (? <=> ?)", e.embedding, ^query_vector)
        },
        where: fragment("1 - (? <=> ?) >= ?", e.embedding, ^query_vector, ^min_similarity),
        order_by: [desc: fragment("1 - (? <=> ?)", e.embedding, ^query_vector)],
        limit: ^limit
      )

    query =
      if is_binary(document_type),
        do: where(query, [e], e.document_type == ^document_type),
        else: query

    query =
      if is_binary(source),
        do: where(query, [e], e.source == ^source),
        else: query

    case repo().all(query) do
      results when is_list(results) ->
        Logger.debug("Found #{length(results)} similar documents")
        {:ok, results}

      {:error, reason} ->
        Logger.error("Search failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Delete all embeddings for a given document ID.

  Returns: :ok | {:error, reason}
  """
  def delete_by_document_id(document_id) when is_binary(document_id) do
    case from(e in Embedding, where: e.document_id == ^document_id) |> repo().delete_all() do
      {count, nil} ->
        Logger.info("Deleted #{count} embeddings for document: #{document_id}")
        :ok

      {:error, reason} ->
        Logger.error("Delete failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def delete_by_document_id(_), do: {:error, :invalid_document_id}

  @doc """
  List all embeddings of a given type.

  Returns: {:ok, [map]} | {:error, reason}
  """
  def list_by_type(document_type) when is_binary(document_type) do
    query =
      from(e in Embedding,
        where: e.document_type == ^document_type,
        select: %{
          id: e.id,
          document_id: e.document_id,
          document_type: e.document_type,
          source: e.source,
          content: e.content,
          metadata: e.metadata
        }
      )

    case repo().all(query) do
      results when is_list(results) ->
        {:ok, results}

      {:error, reason} ->
        Logger.error("List by type failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def list_by_type(_), do: {:error, :invalid_document_type}

  # Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting VectorStore")
    {:ok, opts}
  end
end
