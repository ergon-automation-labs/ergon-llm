defmodule BotArmyLlm.NATS.Consumer do
  @moduledoc """
  NATS message consumer for the LLM bot.

  Subscribes to NATS subjects matching LLM message patterns:
  - `llm.prompt.*` - Prompt-related events

  Messages are decoded using BotArmyCore.NATS.Decoder and routed to
  appropriate handlers based on the event type.

  ## Features

  - Automatic subscription to LLM topics
  - Message decoding and validation
  - Event-based routing to handlers
  - Graceful error handling and recovery
  - Comprehensive logging

  ## Connection Management

  The consumer maintains a persistent NATS connection. If the connection
  is lost, it will attempt to reconnect with exponential backoff.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Callbacks


  @impl true
  def init(opts) do
    Logger.info("Starting LLM NATS consumer")

    state = %{
      subscriptions: [],
      reconnect_attempt: 0,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} -> subscribe_to_topics(conn, state)
      {:error, _reason} -> handle_connection_unavailable(state)
    end
  end

  defp subscribe_to_topics(conn, state) do
    Logger.info("Connected to NATS, subscribing to LLM topics")

    subjects = [
      "llm.prompt.submit",
      "llm.inference.chain",
      "llm.inference.converse",
      "llm.response.parse",
      "llm.vision.analyze",
      "llm.embed.request",
      "llm.rag.index",
      "llm.rag.search",
      "llm.rag.delete",
      "llm.usage.query",
      "llm.metrics.get",
      "llm.queue.status"
    ]

    subs =
      Enum.reduce_while(subjects, [], fn subject, acc ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sub} ->
            Logger.info("LLM consumer subscribed to #{subject}")
            {:cont, [sub | acc]}

          {:error, reason} ->
            Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
            {:halt, acc}
        end
      end)

    case subs do
      subs when length(subs) == length(subjects) ->
        {:noreply, %{state | subscriptions: subs}}

      _ ->
        Logger.error("Failed to subscribe to all LLM topics")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  defp handle_connection_unavailable(state) do
    Logger.warning("NATS connection not ready, will retry")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    Logger.debug("Received NATS message on subject: #{msg.topic}, has_reply_to: #{msg.reply_to != nil}")

    # Handle request/reply messages first (they may not have valid envelope structure)
    if msg.reply_to do
      Logger.debug("Processing request/reply on #{msg.topic}, reply_to: #{msg.reply_to}")
      case BotArmyCore.NATS.Decoder.decode(msg.body) do
        {:ok, decoded_message} ->
          handle_request_reply(msg.topic, decoded_message, msg.reply_to)
        {:error, _reason} ->
          # Request/reply messages may not decode - handle by subject
          handle_request_reply(msg.topic, %{}, msg.reply_to)
      end
    else
      case BotArmyCore.NATS.Decoder.decode(msg.body) do
        {:ok, decoded_message} ->
          route_message(decoded_message)

        {:error, reason} ->
          Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to NATS")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | connection: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Reconnected to NATS")
    {:noreply, state}
  end

  # Private functions

  defp handle_request_reply(subject, message, reply_to) do
    case subject do
      "llm.usage.query" ->
        handle_usage_query(message, reply_to)

      "llm.metrics.get" ->
        handle_metrics_get(message, reply_to)

      "llm.queue.status" ->
        handle_queue_status(message, reply_to)

      _ ->
        Logger.debug("Unknown request/reply subject: #{subject}")
    end
  end

  defp handle_usage_query(message, reply_to) do
    payload = message["payload"] || %{}

    case BotArmyLlm.TokenAccounting.query(build_query_opts(payload)) do
      {:ok, summary} ->
        response = %{
          "event" => "llm.usage.summary",
          "event_id" => message["event_id"],
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_llm",
          "source_node" => node() |> Atom.to_string(),
          "schema_version" => "1.0",
          "payload" => summary
        }

        publish_reply(reply_to, response)

      {:error, reason} ->
        Logger.error("Usage query failed: #{inspect(reason)}")
        error_response = %{
          "event" => "llm.error",
          "event_id" => message["event_id"],
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_llm",
          "source_node" => node() |> Atom.to_string(),
          "schema_version" => "1.0",
          "payload" => %{"error" => "Query failed", "reason" => inspect(reason)}
        }

        publish_reply(reply_to, error_response)
    end
  end

  defp handle_metrics_get(message, reply_to) do
    case BotArmyLlm.Metrics.get_summary() do
      summary when is_map(summary) ->
        response = %{
          "event" => "llm.metrics.summary",
          "event_id" => message["event_id"],
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_llm",
          "source_node" => node() |> Atom.to_string(),
          "schema_version" => "1.0",
          "payload" => summary
        }

        publish_reply(reply_to, response)

      {:error, reason} ->
        Logger.error("Metrics query failed: #{inspect(reason)}")
        error_response = %{
          "event" => "llm.error",
          "event_id" => message["event_id"],
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "bot_army_llm",
          "source_node" => node() |> Atom.to_string(),
          "schema_version" => "1.0",
          "payload" => %{"error" => "Metrics query failed", "reason" => inspect(reason)}
        }

        publish_reply(reply_to, error_response)
    end
  end

  defp handle_queue_status(message, reply_to) do
    Logger.debug("handle_queue_status called, reply_to: #{reply_to}")
    queue_status = BotArmyLlm.LocalQueueManager.queue_status()
    Logger.debug("Queue status: #{inspect(queue_status)}")

    response = %{
      "event" => "llm.queue.status.response",
      "event_id" => message["event_id"],
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => node() |> Atom.to_string(),
      "schema_version" => "1.0",
      "payload" => queue_status
    }

    Logger.debug("Publishing queue status response")
    publish_reply(reply_to, response)
  end

  defp publish_reply(reply_to, response) do
    case Jason.encode(response) do
      {:ok, body} ->
        case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
          {:ok, conn} ->
            Gnat.pub(conn, reply_to, body)

          {:error, reason} ->
            Logger.error("Failed to get NATS connection for reply: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to encode reply: #{inspect(reason)}")
    end
  end

  defp build_query_opts(payload) do
    opts = []

    opts =
      if is_binary(payload["source"]) do
        Keyword.put(opts, :source, payload["source"])
      else
        opts
      end

    opts =
      if is_binary(payload["provider"]) do
        Keyword.put(opts, :provider, payload["provider"])
      else
        opts
      end

    opts
  end

  @doc """
  Route decoded message to appropriate handler based on event type.
  """
  def route_message(message) do
    event = message["event"]

    case event do
      "llm.prompt.submit" ->
        BotArmyLlm.Handlers.PromptHandler.handle_submit(message)

      "llm.inference.chain" ->
        BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)

      "llm.inference.converse" ->
        BotArmyLlm.Handlers.InferenceHandler.handle_converse(message)

      "llm.response.parse" ->
        BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)

      "llm.vision.analyze" ->
        BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)

      "llm.embed.request" ->
        BotArmyLlm.Handlers.EmbeddingHandler.handle_embed(message)

      "llm.rag.index" ->
        BotArmyLlm.Handlers.RAGHandler.handle_index(message)

      "llm.rag.search" ->
        BotArmyLlm.Handlers.RAGHandler.handle_search(message)

      "llm.rag.delete" ->
        BotArmyLlm.Handlers.RAGHandler.handle_delete(message)

      _ ->
        Logger.debug("Unknown LLM event type: #{event}")
    end
  end
end
