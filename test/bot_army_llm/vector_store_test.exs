defmodule BotArmyLlm.VectorStoreTestRepoMock do
  @moduledoc "Mock Repo for VectorStore testing"

  def insert(changeset) do
    case changeset.valid? do
      true ->
        # Return a successful insert with a generated ID
        {:ok, %{
          changeset.data
          | id: UUID.uuid4(),
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
        }}

      false ->
        {:error, changeset}
    end
  end

  def all(_query) do
    # Mock implementation - return empty list by default
    # Tests can override this with Process.put if needed
    Process.get({:vector_store_test, :all_results}, [])
  end

  def delete_all(_query) do
    # Mock implementation - return success
    {1, nil}
  end
end

defmodule BotArmyLlm.VectorStoreTest do
  use ExUnit.Case, async: false

  alias BotArmyLlm.VectorStore

  setup do
    # Inject mock Repo
    Application.put_env(:bot_army_llm, :repo, BotArmyLlm.VectorStoreTestRepoMock)

    on_exit(fn ->
      Application.put_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
    end)

    :ok
  end

  describe "index/1" do
    test "stores a document and returns embedding ID" do
      doc_map = %{
        "document_id" => "doc-1",
        "document_type" => "job_description",
        "source" => "bot_army_job",
        "content" => "Senior Elixir engineer needed",
        "embedding" => create_test_vector(),
        "metadata" => %{"location" => "remote"}
      }

      {:ok, id} = VectorStore.index(doc_map)

      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "rejects invalid document without required fields" do
      doc_map = %{
        "document_id" => "doc-1",
        # missing document_type
        "source" => "bot_army_job",
        "content" => "Test",
        "embedding" => create_test_vector()
      }

      {:error, _reason} = VectorStore.index(doc_map)
    end

    test "stores metadata when provided" do
      doc_map = %{
        "document_id" => "doc-2",
        "document_type" => "gtd_task",
        "source" => "bot_army_gtd",
        "content" => "Complete project",
        "embedding" => create_test_vector(),
        "metadata" => %{"priority" => "high", "due_date" => "2026-03-20"}
      }

      {:ok, _id} = VectorStore.index(doc_map)
    end

    test "rejects non-map input" do
      {:error, :invalid_document} = VectorStore.index(nil)
    end
  end

  describe "search/2" do
    test "returns search results from mock" do
      query_vector = create_test_vector()

      # Mock the search results
      mock_results = [
        %{
          document_id: "doc-1",
          document_type: "job_description",
          source: "bot_army_job",
          content: "Senior Elixir engineer",
          similarity: 0.95
        },
        %{
          document_id: "doc-2",
          document_type: "job_description",
          source: "bot_army_job",
          content: "Junior developer",
          similarity: 0.72
        }
      ]

      Process.put({:vector_store_test, :all_results}, mock_results)

      {:ok, results} = VectorStore.search(query_vector, limit: 5)

      assert is_list(results)
      assert length(results) == 2
    end

    test "respects limit parameter" do
      query_vector = create_test_vector()

      mock_results = [
        %{document_id: "doc-1", similarity: 0.95},
        %{document_id: "doc-2", similarity: 0.72}
      ]

      Process.put({:vector_store_test, :all_results}, mock_results)

      {:ok, results} = VectorStore.search(query_vector, limit: 2)

      assert length(results) <= 2
    end

    test "accepts document_type filter" do
      query_vector = create_test_vector()

      {:ok, _results} = VectorStore.search(query_vector, limit: 5, document_type: "gtd_task")
    end

    test "accepts source filter" do
      query_vector = create_test_vector()

      {:ok, _results} = VectorStore.search(query_vector, limit: 5, source: "bot_army_gtd")
    end

    test "accepts min_similarity filter" do
      query_vector = create_test_vector()

      {:ok, _results} = VectorStore.search(query_vector, limit: 5, min_similarity: 0.8)
    end
  end

  describe "delete_by_document_id/1" do
    test "deletes document by ID" do
      :ok = VectorStore.delete_by_document_id("doc-123")
    end

    test "returns error for invalid document_id" do
      {:error, :invalid_document_id} = VectorStore.delete_by_document_id(nil)
    end

    test "returns error for non-binary input" do
      {:error, :invalid_document_id} = VectorStore.delete_by_document_id(123)
    end
  end

  describe "list_by_type/1" do
    test "returns documents of given type" do
      mock_results = [
        %{
          id: "id-1",
          document_id: "job-1",
          document_type: "job_description",
          source: "bot_army_job",
          content: "Job 1",
          metadata: %{}
        },
        %{
          id: "id-2",
          document_id: "job-2",
          document_type: "job_description",
          source: "bot_army_job",
          content: "Job 2",
          metadata: %{}
        }
      ]

      Process.put({:vector_store_test, :all_results}, mock_results)

      {:ok, results} = VectorStore.list_by_type("job_description")

      assert is_list(results)
      assert length(results) == 2
    end

    test "filters by document type" do
      mock_results = [
        %{document_id: "gtd-1", document_type: "gtd_task"},
        %{document_id: "gtd-2", document_type: "gtd_task"}
      ]

      Process.put({:vector_store_test, :all_results}, mock_results)

      {:ok, results} = VectorStore.list_by_type("gtd_task")

      assert Enum.all?(results, fn r -> r.document_type == "gtd_task" end)
    end

    test "returns empty list for non-existent type" do
      Process.put({:vector_store_test, :all_results}, [])

      {:ok, results} = VectorStore.list_by_type("non_existent_type")

      assert results == []
    end

    test "returns error for invalid type" do
      {:error, :invalid_document_type} = VectorStore.list_by_type(nil)
    end
  end

  # Helper function to create a test vector
  defp create_test_vector do
    # pgvector accepts a list of floats
    List.duplicate(0.1, 768)
  end
end
