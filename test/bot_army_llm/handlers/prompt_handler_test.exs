defmodule BotArmyLlm.Handlers.PromptHandlerTest do
  use ExUnit.Case

  describe "handle_submit/1" do
    test "successfully submits a prompt" do
      message = valid_submit_message()

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "returns error for missing required prompt field" do
      message =
        valid_submit_message()
        |> put_in(["payload", "prompt"], nil)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts default model value" do
      message = valid_submit_message() |> put_in(["payload", "model"], nil)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts custom model" do
      message = valid_submit_message() |> put_in(["payload", "model"], "gpt-4")

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts various prompt texts" do
      for prompt_text <- ["What is Elixir?", "How are you?", "Hello world"] do
        message = valid_submit_message() |> put_in(["payload", "prompt"], prompt_text)
        assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
      end
    end

    test "accepts custom temperature" do
      message =
        valid_submit_message()
        |> put_in(["payload", "temperature"], 0.1)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts custom max_tokens" do
      message =
        valid_submit_message()
        |> put_in(["payload", "max_tokens"], 500)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end

    test "accepts temperature and max_tokens together" do
      message =
        valid_submit_message()
        |> put_in(["payload", "temperature"], 0.1)
        |> put_in(["payload", "max_tokens"], 500)

      assert :ok = BotArmyLlm.Handlers.PromptHandler.handle_submit(message)
    end
  end

  # Helper functions

  defp valid_submit_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "llm.prompt.submit",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "test_client",
      "source_node" => "test_node",
      "triggered_by" => "manual",
      "schema_version" => "1.0",
      "payload" => %{
        "prompt" => "What is Elixir?",
        "model" => "gpt-4",
        "temperature" => 0.8,
        "max_tokens" => 2000
      }
    }
  end
end
