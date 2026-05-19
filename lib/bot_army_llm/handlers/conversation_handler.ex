defmodule BotArmyLlm.Handlers.ConversationHandler do
  @moduledoc """
  Handles conversation-based requests to the LLM bot from other bots.

  Processes incoming `conv.request.llm.*` messages by dispatching
  to LLM inference and routing responses back through the Conversation Manager.

  ## Supported Intents

    - `summarize` — Summarize text (uses :fast LLM hint)
    - `classify` — Classify/categorize text (uses :fast LLM hint)
    - `ask` — Free-form question (uses :quality LLM hint)
    - `run_chain` — Multi-step chain processing (existing chain logic)
    - `gossip.*` — Casual icebreaker messages
  """

  require Logger
  alias BotArmyLlm.NATS.Publisher
  alias BotArmyRuntime.NATS.Conversation.Manager, as: ConversationManager
  alias BotArmyRuntime.NATS.Publisher, as: RuntimePublisher

  @doc """
  Handle an incoming conversation request directed at the LLM bot.
  """
  def handle_request(envelope) do
    payload = envelope["payload"] || envelope
    conversation_id = payload["conversation_id"]
    from_bot = payload["from_bot"]
    message_type = payload["message_type"]
    body = payload["body"] || %{}

    case message_type do
      "query" ->
        handle_query(body, conversation_id, from_bot)

      "command" ->
        handle_command(body, conversation_id, from_bot)

      "gossip" ->
        handle_gossip(body, conversation_id, from_bot)

      _ ->
        Logger.debug("[LLMConv] Unknown message_type from #{from_bot}: #{message_type}")
        :ok
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Handlers
  # ───────────────────────────────────────────────────────────────────────────

  defp handle_query(body, conversation_id, from_bot) do
    intent = body["intent"]
    text = body["text"] || body["message"]

    started_at = System.monotonic_time(:millisecond)

    result =
      case intent do
        "summarize" -> call_llm(text, :fast)
        "classify" -> call_llm(text, :fast)
        "ask" -> call_llm(text, :quality)
        _ -> {:error, :unknown_intent}
      end

    if Process.whereis(BotArmyLlm.Metrics) do
      elapsed = System.monotonic_time(:millisecond) - started_at
      BotArmyLlm.Metrics.record_intent_request(intent)
      BotArmyLlm.Metrics.record_intent_latency(intent, elapsed)
    end

    case result do
      {:ok, response} ->
        ConversationManager.reply(
          conversation_id,
          "llm",
          %{response: response},
          message_type: "result",
          from_bot: from_bot,
          conversation_complete: true
        )

      {:error, reason} ->
        ConversationManager.reply(
          conversation_id,
          "llm",
          %{error: inspect(reason)},
          message_type: "error",
          from_bot: from_bot,
          conversation_complete: true
        )
    end
  end

  defp handle_command(body, conversation_id, from_bot) do
    intent = body["intent"]

    Logger.debug("[LLM Conversation] Command from #{from_bot}: #{intent}")

    result =
      case intent do
        "run_chain" ->
          {:error,
           "run_chain not yet migrated to conversation protocol; use llm.inference.chain directly"}

        _ ->
          {:error, :unknown_intent}
      end

    case result do
      {:ok, response} ->
        ConversationManager.reply(
          conversation_id,
          "llm",
          %{response: response},
          message_type: "result",
          conversation_complete: true
        )

      {:error, reason} ->
        ConversationManager.reply(
          conversation_id,
          "llm",
          %{error: inspect(reason)},
          message_type: "error",
          conversation_complete: true
        )
    end
  end

  defp handle_gossip(body, conversation_id, from_bot) do
    Logger.info("[LLMConv] Gossip from #{from_bot}: #{inspect(body["message"])}")

    response = "Hey #{from_bot}! 👋 I'm here if you need any text processing."

    ConversationManager.reply(
      conversation_id,
      "llm",
      %{response: response},
      message_type: "result",
      conversation_complete: true
    )
  end

  # ───────────────────────────────────────────────────────────────────────────
  # LLM Call
  # ───────────────────────────────────────────────────────────────────────────

  defp call_llm(nil, _hint), do: {:error, "text is required"}
  defp call_llm(text, _hint) when not is_binary(text), do: {:error, "text must be a string"}

  defp call_llm(text, hint) do
    case BotArmy.LLMProxy.request(text, hint: hint, timeout: 30_000) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
