defmodule BotArmyLlm.Http.AnthropicNativeSseStream do
  @moduledoc false
  # Streams Anthropic Messages API (SSE) through to the client unchanged.

  require Logger

  alias BotArmyLlm.Http.SseUsage

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @receive_timeout 120_000

  @spec run(Plug.Conn.t(), map(), String.t(), String.t(), integer()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def run(conn, body, source, event_id, start_ms) when is_map(body) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        model = System.get_env("ANTHROPIC_MODEL_CLAUDE_CODE", "claude-haiku-4-5-20251001")

        payload =
          body
          |> Map.put("model", model)
          |> Map.put("stream", true)

        case Jason.encode(payload) do
          {:ok, json} ->
            req = Finch.build(:post, @anthropic_url, anthropic_headers(key), json)

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
              {:ok, {:upstream_failed, status, _conn}} ->
                {:error, {:http_error, status}}

              {:ok, {conn, meta}} ->
                latency = System.monotonic_time(:millisecond) - start_ms
                {tin, tout} = SseUsage.last_usage_from_sse(meta.buf)

                BotArmyLlm.TokenAccounting.record(%{
                  "event_id" => event_id,
                  "event_type" => "anthropic.messages.stream",
                  "source" => source,
                  "provider" => "anthropic",
                  "model" => model,
                  "tokens_input" => tin,
                  "tokens_output" => tout,
                  "latency_ms" => latency
                })

                Logger.info("http_proxy Anthropic native stream done",
                  source: source,
                  model: model,
                  latency_ms: latency
                )

                {:ok, conn}

              {:error, exception, {conn, _meta}} ->
                Logger.error("http_proxy Anthropic stream failed: #{Exception.message(exception)}")
                {:error, {:stream_exception, exception, conn}}

              other ->
                Logger.error("http_proxy Anthropic stream unexpected: #{inspect(other)}")
                {:error, {:unexpected_result, other}}
            end

          {:error, reason} ->
            {:error, {:encode_error, reason}}
        end

      _ ->
        {:error, {:provider_not_configured, "Anthropic"}}
    end
  end

  defp stream_chunk({:status, status}, {conn, meta}) when meta.phase == :need_status do
    if status == 200 do
      {:cont, {conn, %{meta | phase: :need_headers, status: status}}}
    else
      {:halt, {:upstream_failed, status, conn}}
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
    Logger.warning("http_proxy Anthropic native unexpected chunk: #{inspect(other)}")
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
end
