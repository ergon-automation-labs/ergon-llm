defmodule BotArmyLlm.Http.AnthropicMessagesProxy do
  @moduledoc """
  Proxies Anthropic Messages API requests with Finch streaming for `stream: true`,
  and delegates to `BotArmyLlm.LlmClient.anthropic_passthrough/1` otherwise.

  Streaming uses `BotArmyLlm.ClaudePassthroughStream` — the same provider order as
  **`BOT_ARMY_LLM_CLAUDE_CHAIN`** / `ClaudePassthroughChain` (OpenRouter, Blackbox, Anthropic,
  Ollama as configured).

  Non-streaming uses `LlmClient.anthropic_passthrough/1` (same chain).

  Records usage via `BotArmyLlm.TokenAccounting` with `source` identifying the
  client path (e.g. `claude_code` for `/cc/v1/messages`).
  """

  require Logger

  alias BotArmyLlm.TokenAccounting

  @doc false
  def handle(conn, body, source) when is_map(body) do
    do_handle(conn, body, source)
  rescue
    e ->
      stack = __STACKTRACE__

      if conn.state in [:sent, :chunked] do
        Logger.error("http_proxy handle crashed after response started: #{Exception.format(:error, e, stack)}")
        conn
      else
        Logger.error("http_proxy handle crashed: #{Exception.format(:error, e, stack)}")
        send_json_error(conn, 500, "internal_error", Exception.message(e))
      end
  end

  defp do_handle(conn, body, source) do
    source = normalize_source(source)
    start_ms = System.monotonic_time(:millisecond)
    event_id = Ecto.UUID.generate()
    stream? = body["stream"] == true

    if stream? do
      stream_anthropic(conn, body, source, event_id, start_ms)
    else
      passthrough_json(conn, body, source, event_id, start_ms)
    end
  end

  defp passthrough_json(conn, body, source, event_id, start_ms) do
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    case llm_client.anthropic_passthrough(body) do
      {:ok, response_body} when is_binary(response_body) ->
        latency = System.monotonic_time(:millisecond) - start_ms
        record_from_messages_json(response_body, source, event_id, "anthropic.messages.complete", latency)
        model = model_from_json(response_body) || env_model()

        Logger.info("http_proxy messages complete",
          source: source,
          model: model,
          latency_ms: latency
        )

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json; charset=utf-8")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        |> Plug.Conn.send_resp(200, response_body)

      {:error, reason} ->
        latency = System.monotonic_time(:millisecond) - start_ms
        Logger.error("http_proxy passthrough failed",
          source: source,
          reason: inspect(reason),
          latency_ms: latency
        )

        err =
          Jason.encode!(%{
            "error" => %{
              "type" => "upstream_error",
              "message" => "LLM proxy error: #{inspect(reason)}"
            }
          })

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(502, err)

      {:ok, other} ->
        latency = System.monotonic_time(:millisecond) - start_ms

        Logger.error("http_proxy passthrough returned non-binary {:ok, ...}",
          source: source,
          sample: inspect(other, limit: 200),
          latency_ms: latency
        )

        err =
          Jason.encode!(%{
            "error" => %{
              "type" => "upstream_error",
              "message" => "LLM proxy returned unexpected response shape (expected JSON string)"
            }
          })

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(502, err)

      other ->
        latency = System.monotonic_time(:millisecond) - start_ms

        Logger.error("http_proxy passthrough unexpected result",
          source: source,
          result: inspect(other),
          latency_ms: latency
        )

        err =
          Jason.encode!(%{
            "error" => %{
              "type" => "upstream_error",
              "message" => "LLM proxy error: unexpected result #{inspect(other)}"
            }
          })

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(502, err)
    end
  end

  defp stream_anthropic(conn, body, source, event_id, start_ms) do
    BotArmyLlm.ClaudePassthroughStream.run(conn, body, source, event_id, start_ms)
  end

  defp record_from_messages_json(json, source, event_id, event_type, latency) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        model = Map.get(decoded, "model") || env_model()
        tin = get_in(decoded, ["usage", "input_tokens"])
        tout = get_in(decoded, ["usage", "output_tokens"])
        id = Map.get(decoded, "id")

        provider =
          if is_binary(id) and String.starts_with?(id, "msg-ollama") do
            "ollama"
          else
            "anthropic"
          end

        record_usage(%{
          "event_id" => event_id,
          "event_type" => event_type,
          "source" => source,
          "provider" => provider,
          "model" => model,
          "tokens_input" => tin,
          "tokens_output" => tout,
          "latency_ms" => latency
        })

      _ ->
        :ok
    end
  end

  defp model_from_json(json) do
    case Jason.decode(json) do
      {:ok, %{"model" => m}} when is_binary(m) -> m
      _ -> nil
    end
  end

  defp env_model do
    System.get_env("ANTHROPIC_MODEL_CLAUDE_CODE", "claude-haiku-4-5-20251001")
  end

  defp record_usage(attrs) do
    case TokenAccounting.record(attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("http_proxy token record failed: #{inspect(reason)}")
    end
  end

  defp send_json_error(conn, status, type, message) do
    body = Jason.encode!(%{"error" => %{"type" => type, "message" => message}})

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp normalize_source(source) when is_binary(source) do
    trimmed = String.trim(source)
    if trimmed == "", do: "claude_code", else: trimmed
  end

  defp normalize_source(_), do: "claude_code"
end
