defmodule BotArmyLlm.Http.Router do
  @moduledoc """
  HTTP surface for Anthropic Messages API compatible clients (e.g. Claude Code).

  ## Routes

  - `POST /v1/messages` — default `source` for usage tracking is `claude_code`.
    Override with header `x-bot-army-source: <label>` (e.g. `my_tool`, `ci`).

  - `POST /cc/v1/messages` — same handler; `source` is always `claude_code`
    (explicit path for deployments that want a dedicated URL).

  - `GET /health` — liveness (200 `ok`).

  ## Enabling

  Set `BOT_ARMY_LLM_HTTP_ENABLED=true` and optionally `BOT_ARMY_LLM_HTTP_PORT` (default `39891`).
  Keys stay server-side (`ANTHROPIC_API_KEY`, etc.); clients never send provider keys.

  ## Auth (optional)

  Set `BOT_ARMY_LLM_HTTP_TOKEN`; clients must send `Authorization: Bearer <token>`.

  ## Streaming

  Requests with `"stream": true` are proxied with SSE end-to-end via Finch (Anthropic direct).
  Non-streaming requests use `BotArmyLlm.LlmClient.anthropic_passthrough/1` (includes OpenRouter fallback).

  Usage is recorded in `token_usage` with `event_type` `anthropic.messages.stream` or
  `anthropic.messages.complete` and the chosen `source` for aggregation (`TokenAccounting.query/1`).
  For default `source` `claude_code`, missing `tenant_id` / `user_id` are filled from
  `BotArmyLlm.WellKnownIds` (see `TokenAccounting` moduledoc and pillar `llm.claude_code.identity`).
  """

  use Plug.Router
  require Logger

  alias BotArmyLlm.Http.AnthropicMessagesProxy

  plug :verify_token
  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/cc/v1/messages" do
    dispatch(conn, "claude_code")
  end

  post "/v1/messages" do
    source =
      case Plug.Conn.get_req_header(conn, "x-bot-army-source") do
        [label] when is_binary(label) and label != "" -> String.trim(label)
        _ -> "claude_code"
      end

    dispatch(conn, source)
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"error" => %{"type" => "not_found", "message" => "Not found"}}))
  end

  defp dispatch(conn, source) do
    body = conn.body_params || %{}

    case validate_messages_body(body) do
      :ok ->
        AnthropicMessagesProxy.handle(conn, body, source)

      {:error, reason} ->
        err =
          Jason.encode!(%{
            "error" => %{
              "type" => "invalid_request",
              "message" => "Invalid request: #{inspect(reason)}"
            }
          })

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(400, err)
    end
  end

  defp validate_messages_body(body) when is_map(body) do
    with %{"model" => m} when is_binary(m) and m != "" <- body,
         %{"messages" => msgs} when is_list(msgs) and msgs != [] <- body do
      :ok
    else
      _ -> {:error, :missing_model_or_messages}
    end
  end

  defp verify_token(conn, _opts) do
    cfg = Application.get_env(:bot_army_llm, :http_proxy, [])
    expected = Keyword.get(cfg, :auth_token)

    if is_binary(expected) and expected != "" do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] when token == expected ->
          conn

        _ ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(
            401,
            Jason.encode!(%{"error" => %{"type" => "unauthorized", "message" => "Invalid or missing bearer token"}})
          )
          |> halt()
      end
    else
      conn
    end
  end
end
