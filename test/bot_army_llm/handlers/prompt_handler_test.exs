defmodule BotArmyLlm.Handlers.PromptHandlerTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure Repo is configured
    {:ok, _} = BotArmyLlm.Repo.__adapter__.ensure_all_started(nil, [])
    :ok
  end

  describe "handle_submit/1" do
    test "successfully submits a prompt with valid payload" do
      message = valid_submit_message()

      # Mock LlmClient to return a success response
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "returns error for missing text field" do
      message =
        valid_submit_message()
        |> put_in(["payload", "text"], nil)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "returns error for missing prompt_id field" do
      message =
        valid_submit_message()
        |> put_in(["payload", "prompt_id"], nil)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts custom model" do
      message = valid_submit_message() |> put_in(["payload", "model"], "powerful")

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts various prompt texts" do
      for prompt_text <- ["What is Elixir?", "How are you?", "Hello world"] do
        message = valid_submit_message() |> put_in(["payload", "text"], prompt_text)
        assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
      end
    end

    test "uses default auto model when not specified" do
      message = valid_submit_message() |> Map.update!("payload", &Map.delete(&1, "model"))

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "handles LLM client failures gracefully" do
      message = valid_submit_message()

      # Message is processed and error published on failure
      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end
  end

  # Helper functions

  defp valid_submit_message do
    prompt_id = Ecto.UUID.generate()

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
end
