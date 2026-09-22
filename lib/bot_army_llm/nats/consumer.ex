defmodule BotArmyLlm.NATS.Consumer do
  @moduledoc """
  NATS message consumer for the LLM bot.

  Subscribes to NATS subjects matching LLM message patterns:
  - `llm.prompt.*` - Prompt-related events

  Messages are decoded using BotArmyLibraryCore.NATS.Decoder and routed to
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

  alias BotArmyLibraryCore.NATS.Decoder
  alias BotArmyLlm.EmbeddingWorkerPool
  alias BotArmyLlm.JobStore
  alias BotArmyLibraryRuntime.Registry

  alias BotArmyLlm.Handlers.{
    ClaudeCodeHandler,
    ConversationHandler,
    InferenceHandler,
    NarrativeHandler,
    PromptHandler,
    RAGHandler,
    ResponseHandler,
    SkillExecuteHandler,
    SubtaskHandler,
    VisionHandler
  }

  alias BotArmyLibraryRuntime.Intent.ArmyOpinionVote
  alias BotArmyLibraryRuntime.NATS.Connection

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
    %{
      subject: "llm.job.status",
      type: :request_reply,
      description: "Poll a backgrounded (async) chat job by job_id"
    },
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
      subject: "llm.army.opinion.vote",
      type: :request_reply,
      description: "Army opinion collect voter (persona-style choice)"
    },
    %{
      subject: "dispatcher.subtask.intent.bot_army_llm",
      type: :subscribe,
      description: "Dispatcher subtask intent (Phase 2: autonomous execution)"
    },
    %{
      subject: "bridge.narrative.refresh",
      type: :request_reply,
      description: "Nova narrative generation request"
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
      opts: opts,
      connection: nil,
      # LeaderElection announces the real role shortly after startup; defaulting
      # to standby means a not-yet-elected node never answers business traffic.
      role: :standby
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Connection.subscribe_to_status()
        state = %{state | connection: conn}

        if state.role == :primary do
          subscribe_to_topics(conn, state)
        else
          Logger.info("LLM consumer standby — not subscribing to business subjects")
          {:noreply, register_with_role(%{state | subscriptions: []})}
        end

      {:error, _reason} ->
        handle_connection_unavailable(state)
    end
  end

  @doc """
  Called by `BotArmyLibraryRuntime.LeaderElection`'s `on_role_change` callback.
  """
  def leader_role_changed(role) when role in [:primary, :standby] do
    GenServer.cast(__MODULE__, {:leader_role_changed, role})
  end

  @impl true
  def handle_cast({:leader_role_changed, :primary}, %{connection: nil} = state) do
    Logger.warning(
      "LLM consumer designated PRIMARY, but NATS not connected yet — will subscribe once connected"
    )

    {:noreply, %{state | role: :primary}}
  end

  def handle_cast({:leader_role_changed, :primary}, %{subscriptions: []} = state) do
    Logger.warning("LLM consumer becoming PRIMARY — subscribing to business subjects")
    subscribe_to_topics(state.connection, %{state | role: :primary})
  end

  def handle_cast({:leader_role_changed, :primary}, state) do
    {:noreply, %{state | role: :primary}}
  end

  def handle_cast({:leader_role_changed, :standby}, state) do
    Logger.warning("LLM consumer becoming STANDBY — unsubscribing from business subjects")

    if state.connection do
      Enum.each(state.subscriptions, &Gnat.unsub(state.connection, &1))
    end

    {:noreply, register_with_role(%{state | role: :standby, subscriptions: []})}
  end

  # The subjects this consumer actually subscribes to. It is deliberately its own
  # list, separate from `@subjects` (what the fleet registry is told this bot can
  # answer): the registry entry is also read by other bots to discover peers.
  #
  # Keeping them separate means they can drift — and they did: `llm.job.status`
  # was advertised but never subscribed, so a caller that polled a backgrounded
  # job (the wife care narrator, 0.1.27) would wait forever on a responder that
  # was not there. `subscription_subjects/0` and `advertised_subjects/0` are public
  # so a test can assert every advertised subject is actually subscribed.
  @business_subjects [
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
    "llm.job.status",
    "conv.request.llm.>",
    "conv.mailbox.llm",
    "conv.followup.>",
    "gossip.poll.broadcast",
    "llm.army.opinion.vote",
    "bridge.narrative.refresh",
    # Advertised and handled since Phase 2, but never actually subscribed — the
    # dispatcher's LLM subtasks went nowhere. Inert while no dispatcher runs.
    "dispatcher.subtask.intent.bot_army_llm"
  ]

  @doc "The subjects this consumer subscribes to on the broker."
  @spec subscription_subjects() :: [String.t()]
  def subscription_subjects, do: @business_subjects

  @doc "The subjects this bot advertises to the fleet registry."
  @spec advertised_subjects() :: [String.t()]
  def advertised_subjects, do: Enum.map(@subjects, & &1[:subject])

  defp subscribe_to_topics(conn, state) do
    Logger.info("Connected to NATS, subscribing to LLM topics")

    subjects = @business_subjects

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
        {:noreply, register_with_role(%{state | subscriptions: subs})}

      _ ->
        Logger.error("Failed to subscribe to all LLM topics")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  # Registers with the fleet Registry, reflecting the current role in
  # deployment_status so a standby node is visible but clearly not serving.
  defp register_with_role(state) do
    deployment_status =
      if state.role == :primary do
        Application.get_env(:bot_army_llm, :deployment_status, "deployed")
      else
        "standby"
      end

    BotArmyLibraryRuntime.Registry.register("llm", @subjects, @version, deployment_status)
    Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    state
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
    BotArmyLibraryRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers, []), fn ->
      Logger.debug(
        "Received NATS message on subject: #{msg.topic}, has_reply_to: #{msg.reply_to != nil}"
      )

      process_message(msg)
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

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.role == :primary, do: BotArmyLlm.GossipPollVoter.maybe_vote_on_heartbeat()
    {:noreply, register_with_role(state)}
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
    case Decoder.decode(body) do
      {:ok, decoded_message} ->
        route_message(decoded_message)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{topic}: #{inspect(reason)}")
    end
  end

  defp decode_message_fallback(body) do
    case Decoder.decode(body) do
      {:ok, decoded_message} ->
        decoded_message

      {:error, _reason} ->
        case Jason.decode(body) do
          {:ok, plain} -> plain
          _ -> %{}
        end
    end
  end

  # Private functions

  defp handle_request_reply("llm.claude_code.complete", message, reply_to),
    do: ClaudeCodeHandler.handle_complete(message, reply_to)

  defp handle_request_reply("llm.skill.execute", message, reply_to),
    do: SkillExecuteHandler.handle_execute(message, reply_to)

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

  defp handle_request_reply("llm.job.status", message, reply_to) do
    publish_reply(reply_to, job_status_response(message))
  end

  defp handle_request_reply("llm.army.opinion.vote", message, reply_to) do
    vote = ArmyOpinionVote.build_reply(:llm, message)
    publish_reply(reply_to, vote)
  end

  defp handle_request_reply("bridge.narrative.refresh", message, reply_to),
    do: NarrativeHandler.handle_narrative_request(message, reply_to)

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
      allow_cloud = Map.get(payload, "allow_cloud_when_sensitive", allow_cloud_when_sensitive)

      Logger.warning(
        "[PromptHandler] Received message=#{inspect(message)}, payload=#{inspect(payload)}, text_len=#{byte_size(text || "")}"
      )

      llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

      result =
        try do
          BotArmyLlm.LocalQueueManager.increment()

          if is_nil(text) or text == "" do
            {:error, :empty_prompt}
          else
            llm_client.complete(
              text,
              [
                model: model,
                allow_cloud_when_sensitive: allow_cloud,
                reasoning_mode: reasoning_mode
              ] ++ List.wrap(model_type_opt(payload))
            )
          end
        after
          BotArmyLlm.LocalQueueManager.decrement()
        end

      response =
        case result do
          {:ok, resp} ->
            # Record tokens and cost for metrics
            if Process.whereis(BotArmyLlm.Metrics) do
              tokens_in = Map.get(resp, :tokens_input, 0)
              tokens_out = Map.get(resp, :tokens_output, 0)
              # Cost calculation would go here if we had pricing data in this process
              BotArmyLlm.Metrics.record_tokens_and_cost(
                Atom.to_string(resp.provider),
                resp.model_used,
                tokens_in,
                tokens_out,
                nil
              )
            end

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
    # Read the CALLER's fields, not the envelope's. A decoded envelope nests them
    # under "payload", so reading at this level silently yields an empty prompt and
    # drops every routing opt — and still answers, which looks like a content
    # problem rather than a plumbing one. The bridge survives this only because it
    # duplicates its fields top-level; nesting correctly must not be a penalty.
    payload = chat_payload(message)

    if async_requested?(payload) do
      publish_reply(reply_to, submit_chat_job(payload, subject))
    else
      spawn(fn -> publish_reply(reply_to, run_chat(payload, subject)) end)
    end
  end

  @doc """
  Starts a chat request as a background job and returns the acceptance reply.

  Public and pure-ish (it starts work and returns immediately) so the accepted
  reply's shape is assertable without a broker. The caller polls
  `llm.job.status` with the returned `job_id` on its own schedule — see
  `BotArmyLlm.JobStore`.

  `runner` is the work itself, injectable so tests can exercise the job
  lifecycle without a provider round trip.
  """
  @spec submit_chat_job(map(), String.t(), (map(), String.t() -> map())) :: map()
  def submit_chat_job(payload, subject, runner \\ &run_chat/2) do
    job_id = UUID.uuid4()
    request_id = Map.get(payload, "request_id", UUID.uuid4())
    response_type = Map.get(payload, "request_type", "chat")
    lane = lane_for_chat_subject(subject, payload)

    JobStore.create(job_id, %{
      subject: subject,
      lane: lane,
      request_id: request_id,
      submitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    spawn(fn ->
      try do
        JobStore.complete(job_id, runner.(payload, subject))
      rescue
        error ->
          Logger.error("LLM job #{job_id} failed: #{Exception.message(error)}")
          JobStore.fail(job_id, Exception.message(error))
      catch
        kind, reason ->
          Logger.error("LLM job #{job_id} crashed (#{kind}): #{inspect(reason)}")
          JobStore.fail(job_id, "#{kind}: #{inspect(reason)}")
      end
    end)

    %{
      "request_id" => request_id,
      "response_type" => response_type,
      "lane" => lane,
      "job_id" => job_id,
      "status" => "accepted",
      "poll_subject" => "llm.job.status"
    }
  end

  @doc """
  Whether a chat caller asked for the request to be backgrounded.

  Accepts `true` and `"true"`: pillar/config values arrive as strings in this
  fleet (`explicit_only: "true"`), and a caller that wrote `"true"` meant yes.
  """
  @spec async_requested?(map()) :: boolean()
  def async_requested?(payload) when is_map(payload),
    do: Map.get(payload, "async") in [true, "true"]

  def async_requested?(_other), do: false

  @doc """
  Builds the `llm.job.status` reply for a request message. Public and pure so the
  reply shape is assertable; the private handler only publishes it.

  Mirrors the bridge's `bridge.job.status`: `job_id`, `status`, `result`, `error`.
  """
  @spec job_status_response(map()) :: map()
  def job_status_response(message) do
    case job_id_from(message) do
      nil ->
        %{"ok" => false, "error" => "missing_job_id"}

      job_id ->
        case JobStore.get(job_id) do
          {:error, :not_found} ->
            %{"ok" => false, "error" => "job_not_found", "job_id" => job_id}

          {:ok, job} ->
            %{
              "ok" => true,
              "job_id" => job_id,
              "status" => Atom.to_string(job.status),
              "result" => job.result,
              "error" => job.error,
              "timestamp" =>
                DateTime.from_unix!(job.updated_at, :millisecond) |> DateTime.to_iso8601()
            }
        end
    end
  end

  defp job_id_from(message) do
    payload = chat_payload(message)
    nested = Map.get(payload, "job_id")

    cond do
      is_binary(nested) -> nested
      is_map(message) and is_binary(Map.get(message, "job_id")) -> Map.get(message, "job_id")
      true -> nil
    end
  end

  # The work itself, with no reply and no job bookkeeping: it returns the response
  # map so the synchronous handler can publish it and the async job can store it.
  defp run_chat(payload, subject) do
    request_id = Map.get(payload, "request_id", UUID.uuid4())
    request_type = Map.get(payload, "request_type", "chat")
    lane = lane_for_chat_subject(subject, payload)
    reasoning_mode = Map.get(payload, "reasoning_mode")

    started_at = System.monotonic_time(:millisecond)
    record_lane_metric(:record_lane_request, lane)

    # Support both old format (prompt_context.prompt) and new format (system + messages)
    {result, _chat_opts, prompt_text} =
      if has_anthropic_format?(payload) do
        handle_anthropic_format(payload, lane, reasoning_mode)
      else
        handle_legacy_format(payload, lane, reasoning_mode)
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
            prompt_text,
            request_id,
            request_type,
            lane,
            started_at,
            reason
          )
      end

    record_lane_metric(:record_lane_latency, lane, response["latency_ms"])
    record_chat_outcome(request_id, response)
    response
  end

  defp record_chat_outcome(request_id, response) do
    # Record outcome: LLM chat quality
    try do
      was_successful =
        Map.get(response, "content") != "" and Map.get(response, "content") != nil

      model_used = Map.get(response, "model_used", "auto")

      BotArmyLibraryLearning.OutcomeTracker.record(
        request_id,
        "llm.chat_quality",
        model_used,
        if(was_successful, do: "success", else: "failure"),
        :llm_outcome_tracker
      )
    rescue
      _ -> :ok
    end
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

  # Per-request routing controls that must survive from payload to provider opts.
  # "model" was silently dropped on this path while llm.prompt.submit honored it,
  # and "ollama_node" is what makes an explicit-only node (mini) addressable.
  # "model_type" is validated against a closed allowlist by model_type_opt/1
  # rather than passed through — it names a type, not an arbitrary atom.
  @chat_passthrough [{"model", :model}, {"ollama_node", :ollama_node}]

  @doc """
  Unwrap a decoded envelope down to the caller's payload.

  `Decoder.decode/1` returns the whole envelope, so a caller that nests its fields
  under `"payload"` — the contract shape — is invisible to code that reads the top
  level. The nested payload wins whenever it is a map; a bare payload map passes
  through unchanged, so both producer styles work.

  Public (and pure) for the same reason as `chat_opts/2`: a field read at the wrong
  level is silent, and silence here reads as a model problem — an empty prompt still
  gets a fluent answer.
  """
  @spec chat_payload(map()) :: map()
  def chat_payload(%{"payload" => payload}) when is_map(payload), do: payload
  def chat_payload(message) when is_map(message), do: message
  def chat_payload(_other), do: %{}

  @doc """
  Translate a chat payload's per-request routing controls into provider opts.

  Expects the caller's payload, not the raw envelope — pass `chat_payload/1` first.
  A routing control that is silently dropped here is invisible in the reply, which is
  exactly how "model" was lost on this path once already.
  """
  @spec chat_opts(map(), String.t()) :: keyword()
  def chat_opts(message, lane) when is_map(message) do
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

    lane_opts =
      Enum.reduce(defaults, [], fn {key, default}, acc ->
        value = Map.get(message, Atom.to_string(key), default)
        Keyword.put(acc, key, value)
      end)

    Enum.reduce(@chat_passthrough, lane_opts, fn {payload_key, opt_key}, acc ->
      case message |> Map.get(payload_key) |> trimmed_string() do
        nil -> acc
        value -> Keyword.put(acc, opt_key, value)
      end
    end)
    |> put_model_type(message)
  end

  # A caller asks for a model *type* ("light"|"medium"|"heavy"|"uncensored").
  # Unknown values are dropped with a warning: `String.to_atom/1` on caller input
  # would let any producer mint atoms in the LLM bot, and silently reinterpreting
  # an unknown type would hide a typo behind a plausible answer.
  defp put_model_type(opts, message) do
    case message |> Map.get("model_type") |> BotArmyLlm.ModelType.parse() do
      {:ok, type} ->
        Keyword.put(opts, :model_type, type)

      :error ->
        case message |> Map.get("model_type") |> trimmed_string() do
          nil ->
            opts

          unknown ->
            Logger.warning(
              "llm.request.chat: ignoring unknown model_type #{inspect(unknown)} " <>
                "(allowed: #{Enum.map_join(BotArmyLlm.ModelType.all(), ", ", &Atom.to_string/1)})"
            )

            opts
        end
    end
  end

  defp trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp trimmed_string(_value), do: nil

  # Shared by the prompt path: a model type is a closed allowlist, and absent
  # means absent (no :model_type opt at all).
  defp model_type_opt(payload) do
    case payload |> Map.get("model_type") |> BotArmyLlm.ModelType.parse() do
      {:ok, type} -> {:model_type, type}
      :error -> nil
    end
  end

  defp has_anthropic_format?(message) do
    system = Map.get(message, "system")
    messages = Map.get(message, "messages")
    is_binary(system) and is_list(messages)
  end

  defp handle_anthropic_format(message, lane, reasoning_mode) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    system = Map.get(message, "system")
    messages = Map.get(message, "messages")

    chat_opts =
      message
      |> chat_opts(lane)
      |> Keyword.merge(failed_provider_chat_opts(message, %{}))
      |> Keyword.put(:reasoning_mode, reasoning_mode)

    full_messages = [%{"role" => "system", "content" => system}] ++ messages

    result =
      try do
        BotArmyLlm.LocalQueueManager.increment()
        llm_client.complete_messages(full_messages, chat_opts)
      after
        BotArmyLlm.LocalQueueManager.decrement()
      end

    {result, chat_opts, ""}
  end

  defp handle_legacy_format(message, lane, reasoning_mode) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    prompt_context = Map.get(message, "prompt_context", %{})
    prompt = Map.get(prompt_context, "prompt", "")

    chat_opts =
      message
      |> chat_opts(lane)
      |> Keyword.merge(failed_provider_chat_opts(message, prompt_context))
      |> Keyword.put(:reasoning_mode, reasoning_mode)

    result =
      try do
        BotArmyLlm.LocalQueueManager.increment()
        llm_client.complete(prompt, chat_opts)
      after
        BotArmyLlm.LocalQueueManager.decrement()
      end

    {result, chat_opts, prompt}
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
        case GenServer.call(Connection, :get_connection, 5000) do
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
      ConversationHandler.handle_request(message)
    else
      route_by_event(event, message)
    end
  end

  defp route_by_event("llm.prompt.submit", message),
    do: PromptHandler.handle_submit(message)

  defp route_by_event("llm.skill.prompt.submit", message),
    do: PromptHandler.handle_submit(message)

  defp route_by_event("llm.inference.chain", message),
    do: InferenceHandler.handle_chain(message)

  defp route_by_event("llm.inference.converse", message),
    do: InferenceHandler.handle_converse(message)

  defp route_by_event("llm.response.parse", message),
    do: ResponseHandler.handle_parse(message)

  defp route_by_event("llm.vision.analyze", message),
    do: VisionHandler.handle_analyze(message)

  defp route_by_event("llm.embed.request", message),
    do: EmbeddingWorkerPool.enqueue(message)

  defp route_by_event("llm.embed.request.bulk", message),
    do: EmbeddingWorkerPool.enqueue(message)

  defp route_by_event("llm.rag.index", message),
    do: RAGHandler.handle_index(message)

  defp route_by_event("llm.rag.search", message),
    do: RAGHandler.handle_search(message)

  defp route_by_event("llm.rag.delete", message),
    do: RAGHandler.handle_delete(message)

  defp route_by_event("dispatcher.subtask.intent", message),
    do: SubtaskHandler.handle_subtask_intent(message)

  defp route_by_event(event, _message) do
    Logger.debug("Unknown LLM event type: #{event}")
  end
end
