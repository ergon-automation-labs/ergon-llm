defmodule BotArmyLlm.Http.AnthropicMessagesProxy do
  @moduledoc """
  Proxies Anthropic Messages API requests with Finch streaming for `stream: true`,
  and delegates to `BotArmyLlm.LlmClient.anthropic_passthrough/1` otherwise.

  Streaming tries Anthropic first; on any **non-200** response status it can switch to local
  Ollama SSE (Anthropic-shaped events) when the adapter can convert the request.

  Non-streaming uses `LlmClient.anthropic_passthrough/1` (same chain as `BOT_ARMY_LLM_CLAUDE_CHAIN`).

  Records usage via `BotArmyLlm.TokenAccounting` with `source` identifying the
  client path (e.g. `claude_code` for `/cc/v1/messages`).
  """

  require Logger

  alias BotArmyLlm.Http.{OllamaAnthropicSseStream, SseUsage}
  alias BotArmyLlm.TokenAccounting

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @receive_timeout 120_000

  @doc false
  def handle(conn, body, source) when is_map(body) do
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
    end
  end

  defp stream_anthropic(conn, body, source, event_id, start_ms) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        model = System.get_env("ANTHROPIC_MODEL_CLAUDE_CODE", "claude-haiku-4-5-20251001")

        payload =
          body
          |> Map.put("model", model)
          |> Map.put("stream", true)

        case Jason.encode(payload) do
          {:ok, json} ->
            headers = anthropic_headers(key)
            req = Finch.build(:post, @anthropic_url, headers, json)

            meta = %{
              source: source,
              event_id: event_id,
              start_ms: start_ms,
              model: model,
              phase: :need_status,
              status: nil,
              buf: <<>>
            }

            case Finch.stream_while(
                   req,
                   BotArmyLlm.Finch,
                   {conn, meta},
                   &stream_chunk/2,
                   receive_timeout: @receive_timeout,
                   request_timeout: @receive_timeout
                 ) do
              {:ok, {:ollama_fallback, ollama_conn}} ->
                OllamaAnthropicSseStream.run(ollama_conn, body, source, event_id, start_ms)

              {:ok, {conn, meta}} ->
                latency = System.monotonic_time(:millisecond) - start_ms
                {tin, tout} = SseUsage.last_usage_from_sse(meta.buf)

                record_usage(%{
                  "event_id" => event_id,
                  "event_type" => "anthropic.messages.stream",
                  "source" => source,
                  "provider" => "anthropic",
                  "model" => model,
                  "tokens_input" => tin,
                  "tokens_output" => tout,
                  "latency_ms" => latency
                })

                Logger.info("http_proxy messages stream done",
                  source: source,
                  model: model,
                  latency_ms: latency,
                  tokens_in: tin,
                  tokens_out: tout
                )

                conn

              {:error, exception, {conn, _meta}} ->
                Logger.error("http_proxy stream failed: #{Exception.message(exception)}")

                if conn.state == :chunked do
                  conn
                else
                  err = Jason.encode!(%{"error" => %{"type" => "upstream_error", "message" => "stream failed"}})

                  conn
                  |> Plug.Conn.put_resp_header("content-type", "application/json")
                  |> Plug.Conn.send_resp(502, err)
                end
            end

          {:error, reason} ->
            send_json_error(conn, 500, "encode_error", inspect(reason))
        end

      _ ->
        send_json_error(conn, 503, "provider_not_configured", "ANTHROPIC_API_KEY required for streaming")
    end
  end

  defp stream_chunk({:status, status}, {conn, meta}) when meta.phase == :need_status do
    if status != 200 do
      Logger.warning("http_proxy Anthropic streaming returned status #{status}; switching to Ollama SSE fallback")
      {:halt, {:ollama_fallback, conn}}
    else
      {:cont, {conn, %{meta | phase: :need_headers, status: status}}}
    end
  end

  defp stream_chunk({:headers, headers}, {conn, meta}) when meta.phase == :need_headers do
    content_type = header_ci(headers, "content-type") || "text/event-stream"

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", content_type)
      |> Plug.Conn.put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> Plug.Conn.put_resp_header("pragma", "no-cache")
      |> Plug.Conn.send_chunked(meta.status)

    {:cont, {conn, %{meta | phase: :streaming}}}
  end

  defp stream_chunk({:data, data}, {conn, meta}) when meta.phase == :streaming do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> {:cont, {conn, %{meta | buf: meta.buf <> data}}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp stream_chunk({:trailers, _}, acc), do: {:cont, acc}

  defp stream_chunk(other, acc) do
    Logger.warning("http_proxy unexpected stream chunk: #{inspect(other)}")
    {:cont, acc}
  end

  defp anthropic_headers(api_key) do
    [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "tools-2024-04-04"}
    ]
  end

  defp header_ci(headers, want) do
    w = String.downcase(want)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == w, do: v
    end)
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
