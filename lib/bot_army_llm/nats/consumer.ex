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
      "llm.embed.request"
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
    Logger.debug("Received NATS message on subject: #{msg.topic}")

    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
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

      _ ->
        Logger.debug("Unknown LLM event type: #{event}")
    end
  end
end
