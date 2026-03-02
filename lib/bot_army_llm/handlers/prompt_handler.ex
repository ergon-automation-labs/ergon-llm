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

  @doc """
  Handle prompt submission event.

  Validates the prompt, calls the LLM, counts tokens, and publishes completion event.

  Returns `:ok` if successful, or logs errors on failure.
  """
  def handle_submit(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_submit_payload(payload) do
      :ok ->
        case call_llm(payload) do
          {:ok, response} ->
            Logger.info("LLM completion generated: event_id=#{event_id}")
            publish_completion(payload, response, event_id, message)

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
    with :ok <- require_field(payload, "prompt") do
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
    prompt = payload["prompt"]
    model = Map.get(payload, "model", "gpt-3.5-turbo")
    _temperature = Map.get(payload, "temperature", 0.7)
    _max_tokens = Map.get(payload, "max_tokens", 1000)

    Logger.debug("Calling LLM with prompt: #{String.slice(prompt, 0, 50)}...")

    # Mock LLM response
    completion = generate_mock_completion(prompt, model)

    input_tokens = estimate_tokens(prompt)
    output_tokens = estimate_tokens(completion)

    response = %{
      "completion" => completion,
      "model" => model,
      "tokens" => %{
        "input" => input_tokens,
        "output" => output_tokens,
        "total" => input_tokens + output_tokens
      },
      "latency_ms" => Enum.random(100..500)
    }

    {:ok, response}
  end

  defp generate_mock_completion(prompt, _model) do
    # Mock completion based on prompt content
    p = String.downcase(prompt)
    cond do
      String.contains?(p, "hello") ->
        "Hello! How can I help you today?"

      String.contains?(p, "what") ->
        "That's an interesting question. Let me think about that for a moment. Based on my knowledge, I can provide some insights on this topic."

      String.contains?(p, "how") ->
        "Here's how you can approach this: First, consider the core requirements. Second, break it down into smaller steps. Third, implement and test each component."

      true ->
        "I understand your prompt. This is a mock LLM response for testing purposes. In production, this would be replaced with actual calls to Claude API or similar."
    end
  end

  defp estimate_tokens(text) when is_binary(text) do
    # Simple estimation: ~4 characters per token on average
    String.length(text) / 4 |> Float.round() |> trunc()
  end

  defp estimate_tokens(_), do: 0

  defp publish_completion(payload, response, event_id, _original_message) do
    event_data = %{
      "event" => "llm.completion",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => get_node_name(),
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "completion" => response["completion"],
        "model" => response["model"],
        "tokens" => response["tokens"],
        "latency_ms" => response["latency_ms"],
        "original_prompt_id" => Map.get(payload, "prompt_id", "unknown"),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyLlm.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published completion event")
      {:error, reason} -> Logger.error("Failed to publish completion: #{inspect(reason)}")
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
