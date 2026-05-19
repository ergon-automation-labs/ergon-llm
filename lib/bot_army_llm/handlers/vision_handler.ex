defmodule BotArmyLlm.Handlers.VisionHandler do
  @moduledoc """
  Handles vision/image analysis for the LLM bot.

  This module processes:
  - `llm.vision.analyze` - Image analysis with optional structured output
  """

  require Logger
  alias BotArmyLlm.NATS.Publisher

  alias BotArmyLlm.{EventBuilder, JsonExtractor}

  @doc """
  Handle vision/image analysis requests.

  Analyzes an image using vision models and optionally extracts structured JSON.

  Expected payload structure:
  ```
  {
    "prompt": string (required),
    "image_data": optional base64 string,
    "image_url": optional string,
    "output_schema": optional map for JSON parsing,
    "model": optional string
  }
  ```

  At least one of `image_data` or `image_url` must be provided.

  Publishes:
  - `llm.vision.analyzed` with raw_analysis and structured_data (if schema provided)
  - `llm.error` on failure
  """
  def handle_analyze(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_vision_payload(payload) do
      :ok ->
        process_vision(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid vision payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid vision data", tenant_id, user_id)
    end
  end

  # Private functions

  defp validate_vision_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "prompt") do
      validate_image_fields(payload)
    end
  end

  defp validate_vision_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp validate_image_fields(payload) do
    has_data = is_binary(payload["image_data"]) and payload["image_data"] != ""
    has_url = is_binary(payload["image_url"]) and payload["image_url"] != ""

    if has_data or has_url do
      :ok
    else
      {:error, :no_image_provided}
    end
  end

  defp process_vision(payload, event_id, _original_message, tenant_id, user_id) do
    image_data = payload["image_data"]
    image_url = payload["image_url"]
    prompt = payload["prompt"]
    output_schema = payload["output_schema"]
    model_override = Map.get(payload, "model")

    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    Logger.debug("Analyzing image with vision model")

    BotArmyLlm.LocalQueueManager.increment()

    case llm_client.complete_vision(image_data, image_url, prompt,
           model: model_override || "auto"
         ) do
      {:ok, response} ->
        BotArmyLlm.LocalQueueManager.decrement()
        raw_analysis = response.completion
        structured_data = extract_vision_structured_data(raw_analysis, output_schema)

        publish_analyzed(
          raw_analysis,
          structured_data,
          response.model_used,
          event_id,
          tenant_id,
          user_id
        )

      {:error, reason} ->
        BotArmyLlm.LocalQueueManager.decrement()
        Logger.error("Vision analysis failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Vision analysis failed", tenant_id, user_id)
    end
  end

  defp extract_vision_structured_data(nil, _output_schema), do: nil

  defp extract_vision_structured_data(_raw_analysis, nil), do: nil

  defp extract_vision_structured_data(raw_analysis, output_schema) do
    case JsonExtractor.extract(raw_analysis) do
      {:ok, data} ->
        case JsonExtractor.validate_schema(data, output_schema) do
          :ok ->
            Logger.debug("Vision analysis parsed successfully")
            data

          {:error, :schema_mismatch} ->
            Logger.warning("Vision analysis schema mismatch, returning raw analysis only")
            nil
        end

      {:error, :no_json_found} ->
        Logger.warning("Vision analysis did not contain JSON, returning raw analysis only")
        nil
    end
  end

  defp publish_analyzed(
         raw_analysis,
         structured_data,
         model_used,
         triggered_by_event_id,
         tenant_id,
         user_id
       ) do
    payload = %{
      "raw_analysis" => raw_analysis,
      "model_used" => model_used,
      "triggered_by_event_id" => triggered_by_event_id,
      "tenant_id" => tenant_id,
      "user_id" => user_id
    }

    payload =
      if structured_data do
        Map.put(payload, "structured_data", structured_data)
      else
        payload
      end

    event_data = EventBuilder.build("llm.vision.analyzed", payload)

    case Publisher.publish(event_data) do
      :ok -> Logger.debug("Published vision analysis event")
      {:error, reason} -> Logger.error("Failed to publish vision event: #{inspect(reason)}")
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
