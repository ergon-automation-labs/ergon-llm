defmodule BotArmyLlm.Handlers.EmbeddingHandler do
  @moduledoc """
  Handles embedding generation for the LLM bot.

  This module processes:
  - `llm.embed.request` - Text embedding generation
  """

  require Logger
  alias BotArmyLlm.{EmbeddingConfig, EventBuilder}
  alias BotArmyLlm.NATS.Publisher

  @doc """
  Handle embedding requests.

  Generates vector embeddings for text using the configured embedding model.

  Expected payload structure:
  ```
  {
    "text": string (required),
    "card_id": optional string (for tracking),
    "callback_subject": optional string (for callback),
    "model": optional string (omit for per-provider defaults; set to force the same id on Ollama and OpenRouter)
  }
  ```

  Publishes:
  - `llm.embedding.created` with embedding vector and metadata
  - `llm.error` on failure
  """
  def handle_embed(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_embed_payload(payload) do
      :ok ->
        process_embed(payload, event_id, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid embedding payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid embedding data", tenant_id, user_id)
    end
  end

  # Private functions

  defp validate_embed_payload(payload) when is_map(payload) do
    require_field(payload, "text")
  end

  defp validate_embed_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_embed(payload, event_id, tenant_id, user_id) do
    text = payload["text"]
    card_id = payload["card_id"]
    reference_id = payload["reference_id"]
    model = EmbeddingConfig.optional_explicit_model(Map.get(payload, "model"))

    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    Logger.debug("Generating embedding for text")

    case llm_client.embed(text, model) do
      {:ok, response} ->
        embedding = response.embedding

        publish_embedding(
          embedding,
          response.model_used,
          card_id,
          reference_id,
          event_id,
          tenant_id,
          user_id
        )

      {:error, reason} ->
        Logger.error("Embedding generation failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Embedding generation failed", tenant_id, user_id)
    end
  end

  defp publish_embedding(
         embedding,
         model_used,
         card_id,
         reference_id,
         triggered_by_event_id,
         tenant_id,
         user_id
       ) do
    payload = %{
      "embedding" => embedding,
      "model_used" => model_used,
      "triggered_by_event_id" => triggered_by_event_id,
      "tenant_id" => tenant_id,
      "user_id" => user_id
    }

    payload =
      if card_id do
        Map.put(payload, "card_id", card_id)
      else
        payload
      end

    payload =
      if is_binary(reference_id) and reference_id != "" do
        Map.put(payload, "reference_id", reference_id)
      else
        payload
      end

    event_data = EventBuilder.build("llm.embedding.created", payload)

    case Publisher.publish(event_data) do
      :ok -> Logger.debug("Published embedding event")
      {:error, reason} -> Logger.error("Failed to publish embedding event: #{inspect(reason)}")
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
