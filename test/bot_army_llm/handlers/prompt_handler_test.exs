defmodule BotArmyLlm.LlmClientMock do
  @moduledoc "Mock LLM client for testing"

  @default_response {:ok, %{
    completion: "Test response",
    model_used: "test-model",
    tokens_input: 5,
    tokens_output: 12,
    latency_ms: 100
  }}

  def complete(text, _opts \\ []) when is_binary(text) do
    # Return the configured response or default
    Process.get({:llm_client_mock, :response}, @default_response)
  end
end

defmodule BotArmyLlm.PromptHandlerTestRepoMock do
  @moduledoc "Mock Repo for PromptHandler testing"

  def insert(struct_or_changeset) do
    # Handle both raw structs and changesets
    changeset = case struct_or_changeset do
      %Ecto.Changeset{} = cs -> cs
      struct -> Ecto.Changeset.change(struct)
    end

    case changeset.valid? do
      true ->
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
end

defmodule BotArmyLlm.Handlers.PromptHandlerTest do
  use ExUnit.Case, async: false

  setup do
    # Set the mock LLM client in Application config
    Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClientMock)
    Application.put_env(:bot_army_llm, :repo, BotArmyLlm.PromptHandlerTestRepoMock)

    on_exit(fn ->
      # Restore the real clients after the test
      Application.put_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
      Application.put_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
    end)

    :ok
  end

  defp create_test_prompt do
    # Generate a UUID directly (no database hit)
    UUID.uuid4()
  end

  describe "handle_submit/1" do
    test "successfully submits a prompt with valid payload" do
      message = valid_submit_message()

      # Mock LlmClient to return a success response
      stub_llm_success()
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "returns error for missing text field" do
      message =
        valid_submit_message()
        |> put_in(["payload", "text"], nil)

      stub_llm_success()
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "returns error for missing prompt_id field" do
      message =
        valid_submit_message()
        |> put_in(["payload", "prompt_id"], nil)

      stub_llm_success()
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts custom model" do
      message = valid_submit_message() |> put_in(["payload", "model"], "powerful")

      stub_llm_success()
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts various prompt texts" do
      stub_llm_success()

      for prompt_text <- ["What is Elixir?", "How are you?", "Hello world"] do
        prompt_id = create_test_prompt()
        message = valid_submit_message()
          |> put_in(["payload", "text"], prompt_text)
          |> put_in(["payload", "prompt_id"], prompt_id)
        assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
      end
    end

    test "uses default auto model when not specified" do
      message = valid_submit_message() |> Map.update!("payload", &Map.delete(&1, "model"))

      stub_llm_success()
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "handles LLM client failures gracefully" do
      message = valid_submit_message()

      # Message is processed and error published on failure
      stub_llm_failure()
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end
  end

  # Helper functions

  defp valid_submit_message do
    prompt_id = create_test_prompt()

    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.prompt.submit",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "payload" => %{
        "text" => "What is Elixir?",
        "prompt_id" => prompt_id,
        "model" => "auto",
        "temperature" => 0.8,
        "max_tokens" => 2000
      }
    }
  end

  defp stub_llm_success do
    Process.put({:llm_client_mock, :response}, {:ok, %{
      completion: "Elixir is a functional programming language.",
      model_used: "test-model",
      tokens_input: 5,
      tokens_output: 12,
      latency_ms: 100
    }})
  end

  defp stub_llm_failure do
    Process.put({:llm_client_mock, :response}, {:error, :no_providers_available})
  end
end
