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
  alias BotArmyLibraryRuntime.NATS.Connection
  alias BotArmyLibraryRuntime.NATS.Publisher, as: RuntimePublisher

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

  def publish(_) do
    {:error, :invalid_event}
  end

  # Private functions

  defp do_publish(subject, body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        case RuntimePublisher.publish(subject, payload) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to decode body for #{subject}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp derive_subject(event_type) when is_binary(event_type) do
    known_events = [
      "llm.completion",
      "llm.error",
      "llm.chain.step.completed",
      "llm.chain.completed",
      "llm.conversation.replied",
      "llm.response.parsed",
      "llm.vision.analyzed",
      "llm.embedding.created",
      "llm.rag.indexed",
      "llm.rag.search.result",
      "llm.rag.deleted"
    ]

    if String.starts_with?(event_type, "llm.") and event_type in known_events do
      "events." <> event_type
    else
      "events.llm.unknown"
    end
  end

  defp derive_subject(_) do
    "events.llm.unknown"
  end
end
