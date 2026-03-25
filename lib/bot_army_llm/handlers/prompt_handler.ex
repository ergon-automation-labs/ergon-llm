defmodule BotArmyLlm.Handlers.PromptHandler do
  @moduledoc """
  Handles prompt-related events for the LLM bot.

  This module processes incoming prompt messages:
  - `llm.prompt.submit` - Submit a prompt for LLM inference

  The handler validates the prompt, calls the LLM API (mocked for now),
  tracks token usage, and publishes the completion event.

  ## Dependencies

  - `BotArmyLlm.LlmClient` - LLM API client
  - `BotArmyLlm.NATS.Publisher` - Event publishing
  """

  require Logger

  defp repo do
    Application.get_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
  end

  @doc """
  Handle prompt submission event.

  Validates the prompt, calls the LLM, counts tokens, and publishes completion event.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_submit(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    source_metadata = message["source_metadata"] || %{}

    case validate_submit_payload(payload) do
      :ok ->
        case call_llm(payload) do
          {:ok, response} ->
            Logger.info("LLM completion generated: event_id=#{event_id}")
            publish_completion(payload, response, event_id, source_metadata)

          {:error, reason} ->
            Logger.error("LLM call failed: #{inspect(reason)}")
            publish_error(event_id, reason, "LLM inference failed")
        end

      {:error, reason} ->
        Logger.warning("Invalid prompt payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid prompt data")
    end
  end

  # Private functions

  defp validate_submit_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "text"),
         :ok <- require_field(payload, "prompt_id") do
      :ok
    end
  end

  defp validate_submit_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp call_llm(payload) do
    text = payload["text"]
    model = Map.get(payload, "model", "auto")

    Logger.debug("Calling LLM with prompt: #{String.slice(text, 0, 50)}...")

    # Call configured LLM client (real or mock in tests)
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
    case llm_client.complete(text, model: model) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_completion(payload, response, event_id, source_metadata) do
    prompt_id = payload["prompt_id"]

    # Persist to database
    case persist_completion(prompt_id, response) do
      {:ok, _completion} ->
        Logger.info("Completion persisted to database for prompt #{prompt_id}")

      {:error, reason} ->
        Logger.error("Failed to persist completion: #{inspect(reason)}")
    end

    event_data = %{
      "event" => "llm.completion",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => get_node_name(),
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "completion" => response.completion,
        "model" => response.model_used,
        "tokens" => %{
          "input" => Map.get(response, :tokens_input, 0),
          "output" => Map.get(response, :tokens_output, 0)
        },
        "latency_ms" => response.latency_ms,
        "original_prompt_id" => prompt_id,
        "triggered_by_event_id" => event_id,
        "source_metadata" => source_metadata
      }
    }

    case BotArmyLlm.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published completion event")
      {:error, reason} -> Logger.error("Failed to publish completion: #{inspect(reason)}")
    end
  end

  defp persist_completion(prompt_id, response) do
    case Ecto.UUID.cast(prompt_id) do
      {:ok, uuid} ->
        repo().insert(%BotArmyLlm.Schemas.Completion{
          completion_text: response.completion,
          model_used: response.model_used,
          tokens_input: Map.get(response, :tokens_input),
          tokens_output: Map.get(response, :tokens_output),
          prompt_id: uuid
        })

      :error ->
        {:error, :invalid_prompt_id}
    end
  end

  defp publish_error(event_id, reason, message) do
    error_event = %{
      "event" => "llm.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => get_node_name(),
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyLlm.NATS.Publisher.publish(error_event) do
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
