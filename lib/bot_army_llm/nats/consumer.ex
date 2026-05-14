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
  @registry_heartbeat_ms 20_000
  @pi_go_llm_lane_subjects [
    "pi-go.llm.request.chat.urgent",
    "pi-go.llm.request.chat.interactive",
    "pi-go.llm.request.chat.background"
  ]

  @subjects [
    %{subject: "llm.request.chat", type: :request_reply, description: "Chat request/reply"},
    %{
      subject: "pi-go.llm.request.chat",
      type: :request_reply,
      description: "Pi-go dedicated chat request/reply"
    },
    %{
      subject: "pi-go.llm.request.chat.urgent",
      type: :request_reply,
      description: "Pi-go urgent lane chat request/reply"
    },
    %{
      subject: "pi-go.llm.request.chat.interactive",
      type: :request_reply,
      description: "Pi-go interactive lane chat request/reply"
    },
    %{
      subject: "pi-go.llm.request.chat.background",
      type: :request_reply,
      description: "Pi-go background lane chat request/reply"
    },
    %{subject: "llm.prompt.submit", type: :request_reply, description: "Submit prompt"},
    %{
      subject: "llm.skill.prompt.submit",
      type: :request_reply,
      description: "Dedicated prompt submit for skills execution"
    },
    %{subject: "llm.inference.chain", type: :subscribe, description: "Execute chain"},
    %{subject: "llm.inference.converse", type: :subscribe, description: "Converse"},
    %{subject: "llm.response.parse", type: :subscribe, description: "Parse response"},
    %{subject: "llm.vision.analyze", type: :subscribe, description: "Analyze image"},
    %{subject: "llm.embed.request", type: :subscribe, description: "Generate embedding"},
    %{
      subject: "llm.embed.request.bulk",
      type: :subscribe,
      description: "Generate embedding (bulk/background traffic)"
    },
    %{subject: "llm.rag.index", type: :subscribe, description: "Index document"},
    %{subject: "llm.rag.search", type: :subscribe, description: "Search documents"},
    %{subject: "llm.rag.delete", type: :subscribe, description: "Delete document"},
    %{
      subject: "llm.claude_code.complete",
      type: :request_reply,
      description: "Claude Code completion"
    },
    %{
      subject: "llm.skill.execute",
      type: :request_reply,
      description: "Execute skill through skills bot",
      capabilities: ["skills.execute"]
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
    },
    %{
      subject: "gossip.poll.broadcast",
      type: :subscribe,
      description: "Army general poll broadcasts"
    },
    %{
      subject: "bot_army.llm.intent.summarize",
      type: :subscribe,
      description: "Intent: summarize recent activity"
    },
    %{
      subject: "llm.army.opinion.vote",
      type: :request_reply,
      description: "Army opinion collect voter (persona-style choice)"
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
      "pi-go.llm.request.chat.urgent",
      "pi-go.llm.request.chat.interactive",
      "pi-go.llm.request.chat.background",
      "llm.prompt.submit",
      "llm.skill.prompt.submit",
      "llm.inference.chain",
      "llm.inference.converse",
      "llm.response.parse",
      "llm.vision.analyze",
      "llm.embed.request",
      "llm.embed.request.bulk",
      "llm.rag.index",
      "llm.rag.search",
      "llm.rag.delete",
      "llm.claude_code.complete",
      "llm.skill.execute",
      "llm.usage.query",
      "llm.metrics.get",
      "llm.queue.status",
      "conv.request.llm.>",
      "conv.mailbox.llm",
      "conv.followup.>",
      "gossip.poll.broadcast",
      "llm.army.opinion.vote"
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
      subs when subs != [] and length(subs) == length(subjects) ->
        BotArmyRuntime.Registry.register("llm", @subjects, @version)
        Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
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

      process_message(msg)
    end)

    {:noreply, state}
  end

  defp process_message(%{topic: "gossip.poll.broadcast", body: body}) do
    case Jason.decode(body) do
      {:ok, decoded} -> BotArmyLlm.GossipPollVoter.handle_poll_broadcast(decoded)
      {:error, reason} -> Logger.warning("Failed to decode gossip poll: #{inspect(reason)}")
    end
  end

  defp process_message(%{reply_to: reply_to, topic: topic, body: body})
       when not is_nil(reply_to) do
    Logger.debug("Processing request/reply on #{topic}, reply_to: #{reply_to}")

    decoded = decode_message_fallback(body)

    spawn(fn -> handle_request_reply(topic, decoded, reply_to) end)
  end

  defp process_message(%{body: body, topic: topic}) do
    case BotArmyCore.NATS.Decoder.decode(body) do
      {:ok, decoded_message} ->
        route_message(decoded_message)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{topic}: #{inspect(reason)}")
    end
  end

  defp decode_message_fallback(body) do
    case BotArmyCore.NATS.Decoder.decode(body) do
      {:ok, decoded_message} ->
        decoded_message

      {:error, _reason} ->
        case Jason.decode(body) do
          {:ok, plain} -> plain
          _ -> %{}
        end
    end
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

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.subscriptions != [] do
      BotArmyRuntime.Registry.register("llm", @subjects, @version)
      BotArmyLlm.GossipPollVoter.maybe_vote_on_heartbeat()
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  # Private functions

  defp handle_request_reply("llm.claude_code.complete", message, reply_to),
    do: BotArmyLlm.Handlers.ClaudeCodeHandler.handle_complete(message, reply_to)

  defp handle_request_reply("llm.skill.execute", message, reply_to),
    do: BotArmyLlm.Handlers.SkillExecuteHandler.handle_execute(message, reply_to)

  defp handle_request_reply("llm.prompt.submit", message, reply_to),
    do: handle_prompt_request_reply(message, reply_to, false)

  defp handle_request_reply("llm.skill.prompt.submit", message, reply_to),
    do: handle_prompt_request_reply(message, reply_to, true)

  defp handle_request_reply(subject, message, reply_to)
       when subject in ["llm.request.chat", "pi-go.llm.request.chat"] or
              subject in @pi_go_llm_lane_subjects,
       do: handle_chat_request_reply(subject, message, reply_to)

  defp handle_request_reply("llm.usage.query", message, reply_to),
    do: handle_usage_query(message, reply_to)

  defp handle_request_reply("llm.metrics.get", message, reply_to),
    do: handle_metrics_get(message, reply_to)

  defp handle_request_reply("llm.queue.status", message, reply_to),
    do: handle_queue_status(message, reply_to)

  defp handle_request_reply("llm.army.opinion.vote", message, reply_to) do
    vote = BotArmyRuntime.Intent.ArmyOpinionVote.build_reply(:llm, message)
    publish_reply(reply_to, vote)
  end

  defp handle_request_reply(subject, _message, _reply_to) do
    Logger.debug("Unknown request/reply subject: #{subject}")
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

  defp handle_prompt_request_reply(message, reply_to, allow_cloud_when_sensitive) do
    spawn(fn ->
      payload = message["payload"] || message
      text = payload["text"]
      model = Map.get(payload, "model", "auto")
      prompt_id = Map.get(payload, "prompt_id", UUID.uuid4())
      reasoning_mode = Map.get(payload, "reasoning_mode")

      llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

      result =
        try do
          BotArmyLlm.LocalQueueManager.increment()

          llm_client.complete(text,
            model: model,
            allow_cloud_when_sensitive: allow_cloud_when_sensitive,
            reasoning_mode: reasoning_mode
          )
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

  defp handle_chat_request_reply(subject, message, reply_to) do
    spawn(fn ->
      request_id = Map.get(message, "request_id", UUID.uuid4())
      request_type = Map.get(message, "request_type", "chat")
      prompt_context = Map.get(message, "prompt_context", %{})
      prompt = Map.get(prompt_context, "prompt", "")
      lane = lane_for_chat_subject(subject, message)
      reasoning_mode = Map.get(message, "reasoning_mode")

      chat_opts =
        message
        |> chat_opts_for_lane(lane)
        |> Keyword.merge(failed_provider_chat_opts(message, prompt_context))
        |> Keyword.put(:reasoning_mode, reasoning_mode)

      llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

      started_at = System.monotonic_time(:millisecond)
      record_lane_metric(:record_lane_request, lane)

      result =
        try do
          BotArmyLlm.LocalQueueManager.increment()
          llm_client.complete(prompt, chat_opts)
        after
          BotArmyLlm.LocalQueueManager.decrement()
        end

      response =
        case result do
          {:ok, resp} ->
            %{
              "request_id" => request_id,
              "response_type" => request_type,
              "model_used" => Map.get(resp, :model_used, "auto"),
              "content" => Map.get(resp, :completion, ""),
              "cache_hit" => false,
              "lane" => lane,
              "latency_ms" => System.monotonic_time(:millisecond) - started_at,
              "tokens" => %{
                "input" => Map.get(resp, :tokens_input, 0),
                "output" => Map.get(resp, :tokens_output, 0)
              }
            }

          {:error, reason} ->
            maybe_fallback_chat_response(
              prompt,
              request_id,
              request_type,
              lane,
              started_at,
              reason
            )
        end

      record_lane_metric(:record_lane_latency, lane, response["latency_ms"])

      publish_reply(reply_to, response)
    end)
  end

  defp lane_for_chat_subject(subject, message) do
    payload_lane =
      case Map.get(message, "priority") do
        lane when lane in ["urgent", "interactive", "background"] -> lane
        _ -> nil
      end

    subject_lane =
      cond do
        subject == "pi-go.llm.request.chat.urgent" -> "urgent"
        subject == "pi-go.llm.request.chat.background" -> "background"
        subject == "pi-go.llm.request.chat.interactive" -> "interactive"
        true -> nil
      end

    payload_lane || subject_lane || "interactive"
  end

  defp failed_provider_chat_opts(message, prompt_context) do
    failed =
      (collect_failed_providers(prompt_context) ++ collect_failed_providers(message))
      |> Enum.map(&normalize_failed_provider_name/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case failed do
      [] ->
        []

      providers ->
        [failed_providers: providers, provider_failed: List.last(providers)]
    end
  end

  defp collect_failed_providers(%{} = map) do
    Enum.flat_map(
      ["failed_providers", "provider_failed"],
      fn key ->
        case Map.get(map, key) do
          list when is_list(list) -> list
          value when is_binary(value) -> [value]
          _ -> []
        end
      end
    )
  end

  defp collect_failed_providers(_), do: []

  defp normalize_failed_provider_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading(":")
    |> String.downcase()
  end

  defp normalize_failed_provider_name(value) when is_atom(value),
    do: normalize_failed_provider_name(Atom.to_string(value))

  defp normalize_failed_provider_name(_), do: ""

  defp chat_opts_for_lane(message, lane) do
    # Tiered defaults keep foreground traffic snappy and background traffic cheaper.
    # Explicit caller options still win when present.
    defaults =
      case lane do
        "urgent" ->
          [temperature: 0.2, max_tokens: 400, allow_cloud_when_sensitive: false]

        "background" ->
          [temperature: 0.7, max_tokens: 250, allow_cloud_when_sensitive: true]

        _ ->
          [temperature: 0.5, max_tokens: 700, allow_cloud_when_sensitive: false]
      end

    Enum.reduce(defaults, [], fn {key, default}, acc ->
      value = Map.get(message, Atom.to_string(key), default)
      Keyword.put(acc, key, value)
    end)
  end

  defp record_lane_metric(:record_lane_request, lane) do
    if Process.whereis(BotArmyLlm.Metrics) do
      BotArmyLlm.Metrics.record_lane_request(lane)
    end
  end

  defp record_lane_metric(:record_lane_latency, lane, latency_ms) when is_integer(latency_ms) do
    if Process.whereis(BotArmyLlm.Metrics) do
      BotArmyLlm.Metrics.record_lane_latency(lane, latency_ms)
    end
  end

  defp maybe_fallback_chat_response(prompt, request_id, request_type, lane, started_at, reason) do
    latency_ms = System.monotonic_time(:millisecond) - started_at

    if llm_capacity_error?(reason) do
      %{
        "request_id" => request_id,
        "response_type" => request_type,
        "model_used" => "deterministic_fallback",
        "provider" => "local_fallback",
        "content" => deterministic_fallback_content(prompt),
        "cache_hit" => false,
        "degraded" => true,
        "degrade_reason" => inspect(reason),
        "lane" => lane,
        "latency_ms" => latency_ms,
        "tokens" => %{"input" => 0, "output" => 0}
      }
    else
      %{
        "request_id" => request_id,
        "response_type" => request_type,
        "error" => inspect(reason),
        "cache_hit" => false,
        "lane" => lane,
        "latency_ms" => latency_ms
      }
    end
  end

  defp llm_capacity_error?(:no_providers_available), do: true
  defp llm_capacity_error?(:provider_not_configured), do: true
  defp llm_capacity_error?({:ollama_unavailable, _}), do: true
  defp llm_capacity_error?(_), do: false

  defp deterministic_fallback_content(prompt) when is_binary(prompt) do
    down = String.downcase(prompt)

    if String.contains?(down, "file writing") or
         String.contains?(down, "write files") or
         String.contains?(down, "write capability") do
      "LLM providers are temporarily unavailable, so I cannot verify runtime tool capability right now. " <>
        "Please run a quick direct capability probe in your agent runtime (for example a small temp file write/read test) and retry."
    else
      "LLM providers are temporarily unavailable. I can still return partial context and deterministic checks, " <>
        "or you can retry in a few seconds for full model-backed output."
    end
  end

  defp deterministic_fallback_content(_prompt) do
    "LLM providers are temporarily unavailable. Please retry in a few seconds."
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

    if is_binary(event) and String.starts_with?(event, "conv.") do
      BotArmyLlm.Handlers.ConversationHandler.handle_request(message)
    else
      route_by_event(event, message)
    end
  end

  defp route_by_event("llm.prompt.submit", message),
    do: BotArmyLlm.Handlers.PromptHandler.handle_submit(message)

  defp route_by_event("llm.skill.prompt.submit", message),
    do: BotArmyLlm.Handlers.PromptHandler.handle_submit(message)

  defp route_by_event("llm.inference.chain", message),
    do: BotArmyLlm.Handlers.InferenceHandler.handle_chain(message)

  defp route_by_event("llm.inference.converse", message),
    do: BotArmyLlm.Handlers.InferenceHandler.handle_converse(message)

  defp route_by_event("llm.response.parse", message),
    do: BotArmyLlm.Handlers.ResponseHandler.handle_parse(message)

  defp route_by_event("llm.vision.analyze", message),
    do: BotArmyLlm.Handlers.VisionHandler.handle_analyze(message)

  defp route_by_event("llm.embed.request", message),
    do: spawn_embedding_handler(message)

  defp route_by_event("llm.embed.request.bulk", message),
    do: spawn_embedding_handler(message)

  defp route_by_event("llm.rag.index", message),
    do: BotArmyLlm.Handlers.RAGHandler.handle_index(message)

  defp route_by_event("llm.rag.search", message),
    do: BotArmyLlm.Handlers.RAGHandler.handle_search(message)

  defp route_by_event("llm.rag.delete", message),
    do: BotArmyLlm.Handlers.RAGHandler.handle_delete(message)

  defp route_by_event(event, _message) do
    Logger.debug("Unknown LLM event type: #{event}")
  end

  defp spawn_embedding_handler(message) do
    spawn(fn -> BotArmyLlm.Handlers.EmbeddingHandler.handle_embed(message) end)
  end
end
