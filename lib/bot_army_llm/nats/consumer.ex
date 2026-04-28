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
  @version Mix.Project.config()[:version]

  @subjects [
    %{subject: "llm.request.chat", type: :request_reply, description: "Chat request/reply"},
    %{
      subject: "pi-go.llm.request.chat",
      type: :request_reply,
      description: "Pi-go dedicated chat request/reply"
    },
    %{subject: "llm.prompt.submit", type: :request_reply, description: "Submit prompt"},
    %{subject: "llm.inference.chain", type: :subscribe, description: "Execute chain"},
    %{subject: "llm.inference.converse", type: :subscribe, description: "Converse"},
    %{subject: "llm.response.parse", type: :subscribe, description: "Parse response"},
    %{subject: "llm.vision.analyze", type: :subscribe, description: "Analyze image"},
    %{subject: "llm.embed.request", type: :subscribe, description: "Generate embedding"},
    %{subject: "llm.rag.index", type: :subscribe, description: "Index document"},
    %{subject: "llm.rag.search", type: :subscribe, description: "Search documents"},
    %{subject: "llm.rag.delete", type: :subscribe, description: "Delete document"},
    %{
      subject: "llm.claude_code.complete",
      type: :request_reply,
      description: "Claude Code completion"
    },
    %{subject: "llm.usage.query", type: :request_reply, description: "Query token usage"},
    %{subject: "llm.metrics.get", type: :request_reply, description: "Get metrics"},
    %{subject: "llm.queue.status", type: :request_reply, description: "Get queue status"},
    # Cross-bot conversation protocol
    %{
      subject: "conv.request.llm.*",
      type: :subscribe,
      description: "Cross-bot conversation requests",
      capabilities: ["llm.summarize", "llm.classify", "llm.ask"],
      conversation_support: %{supported: true, message_types: ["query", "gossip"], max_turns: 2}
    },
    %{
      subject: "conv.mailbox.llm",
      type: :subscribe,
      description: "Cross-bot mailbox messages",
      capabilities: ["gossip.check_in"]
    },
    %{
      subject: "conv.followup.*",
      type: :subscribe,
      description: "Multi-turn conversation followups"
    }
  ]

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
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        subscribe_to_topics(conn, state)

      {:error, _reason} ->
        handle_connection_unavailable(state)
    end
  end

  defp subscribe_to_topics(conn, state) do
    Logger.info("Connected to NATS, subscribing to LLM topics")

    subjects = [
      "llm.request.chat",
      "pi-go.llm.request.chat",
      "llm.prompt.submit",
      "llm.inference.chain",
      "llm.inference.converse",
      "llm.response.parse",
      "llm.vision.analyze",
      "llm.embed.request",
      "llm.rag.index",
      "llm.rag.search",
      "llm.rag.delete",
      "llm.claude_code.complete",
      "llm.usage.query",
      "llm.metrics.get",
      "llm.queue.status",
      "conv.request.llm.>",
      "conv.mailbox.llm",
      "conv.followup.>"
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
        BotArmyRuntime.Registry.register("llm", @subjects, @version)
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
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers, []), fn ->
      Logger.debug(
        "Received NATS message on subject: #{msg.topic}, has_reply_to: #{msg.reply_to != nil}"
      )

      # Handle request/reply messages first (they may not have valid envelope structure)
      if msg.reply_to do
        Logger.debug("Processing request/reply on #{msg.topic}, reply_to: #{msg.reply_to}")

        decoded =
          case BotArmyCore.NATS.Decoder.decode(msg.body) do
            {:ok, decoded_message} ->
              decoded_message

            {:error, _reason} ->
              # Request/reply messages may not follow envelope format — try plain JSON
              case Jason.decode(msg.body) do
                {:ok, plain} -> plain
                _ -> %{}
              end
          end

        handle_request_reply(msg.topic, decoded, msg.reply_to)
      else
        case BotArmyCore.NATS.Decoder.decode(msg.body) do
          {:ok, decoded_message} ->
            route_message(decoded_message)

          {:error, reason} ->
            Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
        end
      end
    end)

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
    {:noreply, %{state | subscriptions: [], connection: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  # Private functions

  defp handle_request_reply(subject, message, reply_to) do
    case subject do
      "llm.claude_code.complete" ->
        BotArmyLlm.Handlers.ClaudeCodeHandler.handle_complete(message, reply_to)

      "llm.prompt.submit" ->
        handle_prompt_request_reply(message, reply_to)

      "llm.request.chat" ->
        handle_chat_request_reply(message, reply_to)

      "pi-go.llm.request.chat" ->
        handle_chat_request_reply(message, reply_to)

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

  defp handle_prompt_request_reply(message, reply_to) do
    spawn(fn ->
      payload = message["payload"] || message
      text = payload["text"]
      model = Map.get(payload, "model", "auto")
      prompt_id = Map.get(payload, "prompt_id", UUID.uuid4())

      llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

      result =
        try do
          BotArmyLlm.LocalQueueManager.increment()
          llm_client.complete(text, model: model)
        after
          BotArmyLlm.LocalQueueManager.decrement()
        end

      response =
        case result do
          {:ok, resp} ->
            %{
              "completion" => resp.completion,
              "model" => resp.model_used,
              "tokens" => %{
                "input" => Map.get(resp, :tokens_input, 0),
                "output" => Map.get(resp, :tokens_output, 0)
              },
              "prompt_id" => prompt_id
            }

          {:error, reason} ->
            %{"error" => inspect(reason), "prompt_id" => prompt_id}
        end

      publish_reply(reply_to, response)
    end)
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

  defp handle_chat_request_reply(message, reply_to) do
    spawn(fn ->
      request_id = Map.get(message, "request_id", UUID.uuid4())
      request_type = Map.get(message, "request_type", "chat")
      prompt_context = Map.get(message, "prompt_context", %{})
      prompt = Map.get(prompt_context, "prompt", "")
      model_preference = Map.get(message, "model_preference", "auto")

      llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

      started_at = System.monotonic_time(:millisecond)

      result =
        try do
          BotArmyLlm.LocalQueueManager.increment()
          llm_client.complete(prompt, model: model_preference)
        after
          BotArmyLlm.LocalQueueManager.decrement()
        end

      response =
        case result do
          {:ok, resp} ->
            %{
              "request_id" => request_id,
              "response_type" => request_type,
              "model_used" => Map.get(resp, :model_used, model_preference),
              "content" => Map.get(resp, :completion, ""),
              "cache_hit" => false,
              "latency_ms" => System.monotonic_time(:millisecond) - started_at,
              "tokens" => %{
                "input" => Map.get(resp, :tokens_input, 0),
                "output" => Map.get(resp, :tokens_output, 0)
              }
            }

          {:error, reason} ->
            %{
              "request_id" => request_id,
              "response_type" => request_type,
              "error" => inspect(reason),
              "cache_hit" => false,
              "latency_ms" => System.monotonic_time(:millisecond) - started_at
            }
        end

      publish_reply(reply_to, response)
    end)
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

    cond do
      is_binary(event) and String.starts_with?(event, "conv.request.llm.") ->
        BotArmyLlm.Handlers.ConversationHandler.handle_request(message)

      is_binary(event) and String.starts_with?(event, "conv.followup.") ->
        BotArmyLlm.Handlers.ConversationHandler.handle_request(message)

      true ->
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
end
