defmodule BotArmyLlm.NATS.Publisher do
  @moduledoc """
  NATS event publisher for the LLM bot.

  Publishes response events from LLM handlers back to the NATS broker.
  Events include llm.completion and error events.

  ## Features

  - Serialization of events to JSON
  - Subject routing based on event type
  - Error handling and logging
  - Connection management
  """

  require Logger

  @doc """
  Publish an event to NATS.

  The event map should contain:
  - `"event"` - Event type (e.g., "llm.completion")
  - `"event_id"` - Unique event identifier
  - `"timestamp"` - ISO8601 timestamp
  - `"source"` - Source bot (e.g., "bot_army_llm")
  - `"source_node"` - Node name
  - `"triggered_by"` - Audit value
  - `"schema_version"` - Schema version
  - `"payload"` - Event payload

  Returns `:ok` if successful, or `{:error, reason}` on failure.
  """
  def publish(event) when is_map(event) do
    try do
      subject = derive_subject(event["event"])
      body = Jason.encode!(event)

      case do_publish(subject, body) do
        :ok ->
          Logger.debug("Published event to #{subject}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to publish to #{subject}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Exception during publish: #{inspect(e)}")
        {:error, e}
    catch
      :exit, reason ->
        Logger.warning("NATS not available, dropping event: #{inspect(reason)}")
        {:error, :nats_unavailable}
    end
  end

  def publish(_) do
    {:error, :invalid_event}
  end

  # Private functions

  defp do_publish(subject, body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        case BotArmyRuntime.NATS.Publisher.publish(subject, payload) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to decode body for #{subject}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp derive_subject(event_type) when is_binary(event_type) do
    case event_type do
      "llm.completion" -> "events.llm.completion"
      "llm.completion." <> _rest -> "events." <> event_type
      "llm.error" -> "events.llm.error"
      "llm.chain.step.completed" -> "events.llm.chain.step.completed"
      "llm.chain.completed" -> "events.llm.chain.completed"
      "llm.conversation.replied" -> "events.llm.conversation.replied"
      "llm.response.parsed" -> "events.llm.response.parsed"
      "llm.vision.analyzed" -> "events.llm.vision.analyzed"
      "llm.embedding.created" -> "events.llm.embedding.created"
      "llm.rag.indexed" -> "events.llm.rag.indexed"
      "llm.rag.search.result" -> "events.llm.rag.search.result"
      "llm.rag.deleted" -> "events.llm.rag.deleted"
      _ -> "events.llm.unknown"
    end
  end

  defp derive_subject(_) do
    "events.llm.unknown"
  end
end
