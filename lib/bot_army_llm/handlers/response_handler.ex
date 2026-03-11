defmodule BotArmyLlm.Handlers.ResponseHandler do
  @moduledoc """
  Handles response parsing and validation for the LLM bot.

  This module processes:
  - `llm.response.parse` - Extract and validate JSON from LLM responses
  """

  require Logger

  alias BotArmyLlm.{EventBuilder, JsonExtractor}

  @doc """
  Handle response parsing requests.

  Extracts JSON from text responses and validates against an optional schema.
  On extraction failure, retries with a corrective LLM prompt.

  Expected payload structure:
  ```
  {
    "text": string (required),
    "output_schema": optional map for validation,
    "max_retries": optional integer (default 3)
  }
  ```

  Publishes:
  - `llm.response.parsed` on success with structured_data
  - `llm.error` on failure after max retries
  """
  def handle_parse(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_parse_payload(payload) do
      :ok ->
        process_parse(payload, event_id, message)

      {:error, reason} ->
        Logger.warning("Invalid parse payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid parse data")
    end
  end

  # Private functions

  defp validate_parse_payload(payload) when is_map(payload) do
    require_field(payload, "text")
  end

  defp validate_parse_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_parse(payload, event_id, _original_message) do
    text = payload["text"]
    output_schema = payload["output_schema"]
    max_retries = Map.get(payload, "max_retries", 3)

    # Pass through any context fields the caller included (e.g. inbox_item_id, source)
    context = Map.drop(payload, ["text", "output_schema", "max_retries"])

    Logger.debug("Parsing JSON response (max_retries=#{max_retries})")

    case attempt_parse(text, output_schema, max_retries, 0) do
      {:ok, structured_data} ->
        publish_parsed(structured_data, context, event_id)

      {:error, reason} ->
        Logger.error("Failed to parse response after #{max_retries} retries: #{inspect(reason)}")
        publish_error(event_id, reason, "Failed to parse response")
    end
  end

  defp attempt_parse(text, schema, max_retries, attempt) when attempt < max_retries do
    case JsonExtractor.extract(text) do
      {:ok, data} ->
        case JsonExtractor.validate_schema(data, schema) do
          :ok ->
            Logger.info("JSON extracted and validated on attempt #{attempt + 1}")
            {:ok, data}

          {:error, :schema_mismatch} ->
            if attempt + 1 < max_retries do
              Logger.warning("Schema mismatch on attempt #{attempt + 1}, retrying with correction")
              retry_with_correction(text, schema, max_retries, attempt + 1)
            else
              {:error, :schema_mismatch}
            end
        end

      {:error, :no_json_found} ->
        if attempt + 1 < max_retries do
          Logger.warning("No JSON found on attempt #{attempt + 1}, retrying with correction")
          retry_with_correction(text, schema, max_retries, attempt + 1)
        else
          {:error, :no_json_found}
        end
    end
  end

  defp attempt_parse(_text, _schema, _max_retries, _attempt) do
    {:error, :max_retries_exceeded}
  end

  defp retry_with_correction(original_text, schema, max_retries, attempt) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    # Build a corrective prompt
    schema_str =
      if schema do
        Jason.encode!(schema)
      else
        "valid JSON"
      end

    corrective_prompt = """
    Extract and return ONLY valid JSON matching this schema: #{schema_str}

    Source text:
    #{original_text}

    Return ONLY the JSON, no other text.
    """

    case llm_client.complete(corrective_prompt, model: "auto") do
      {:ok, response} ->
        new_text = response.completion
        attempt_parse(new_text, schema, max_retries, attempt)

      {:error, reason} ->
        Logger.error("Correction attempt #{attempt} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp publish_parsed(structured_data, context, triggered_by_event_id) do
    event_data = EventBuilder.build("llm.response.parsed", Map.merge(context, %{
      "structured_data" => structured_data,
      "triggered_by_event_id" => triggered_by_event_id
    }))

    case BotArmyLlm.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published parsed response event")
      {:error, reason} -> Logger.error("Failed to publish parsed event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message) do
    error_event = %{
      "event" => "llm.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => node() |> Atom.to_string(),
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
end
