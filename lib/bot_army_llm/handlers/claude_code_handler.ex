defmodule BotArmyLlm.Handlers.ClaudeCodeHandler do
  @moduledoc """
  Handles Claude Code direct API requests via HTTP gateway.

  This handler processes requests from the CC HTTP LLM Gateway, which forwards
  Anthropic Messages API requests from Claude Code through the LLM proxy.

  Receives the full Anthropic Messages API payload (messages, tools, system, etc.)
  and passes it through directly to Anthropic, preserving all features.

  Subject: `llm.claude_code.complete` (request/reply pattern)
  """

  require Logger

  @doc """
  Handle Claude Code request via request/reply.

  Receives NATS envelope where payload = full Anthropic Messages API body.
  Replies to `reply_to` with the raw Anthropic API response JSON.
  """
  def handle_complete(message, reply_to) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    Logger.debug("Processing Claude Code request", payload: inspect(payload))

    case validate_claude_code_payload(payload) do
      :ok ->
        process_claude_code(payload, event_id, reply_to, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid Claude Code payload: #{inspect(reason)}")
        publish_error_reply(reply_to, event_id, reason, "Invalid request payload", tenant_id, user_id)
    end
  end

  # Private functions

  defp validate_claude_code_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "model"),
         :ok <- require_field(payload, "messages") do
      :ok
    end
  end

  defp validate_claude_code_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_claude_code(payload, event_id, reply_to, tenant_id, user_id) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    Logger.debug("Calling LLM for Claude Code request")

    case llm_client.anthropic_passthrough(payload) do
      {:ok, response_body} ->
        Logger.debug("Claude Code request succeeded")
        publish_reply(reply_to, response_body)

      {:error, reason} ->
        Logger.error("Claude Code request failed: #{inspect(reason)}")
        publish_error_reply(reply_to, event_id, reason, "LLM request failed", tenant_id, user_id)
    end
  end

  defp publish_reply(reply_to, response_body) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Gnat.pub(conn, reply_to, response_body)

      {:error, reason} ->
        Logger.error("Failed to get NATS connection for reply: #{inspect(reason)}")
    end
  end

  defp publish_error_reply(reply_to, event_id, _reason, message, tenant_id, user_id) do
    error_body =
      Jason.encode!(%{
        "error" => %{
          "type" => "internal_error",
          "message" => message
        },
        "triggered_by_event_id" => event_id,
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Gnat.pub(conn, reply_to, error_body)

      {:error, err} ->
        Logger.error("Failed to publish error reply: #{inspect(err)}")
    end
  end
end
