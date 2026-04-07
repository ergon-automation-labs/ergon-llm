defmodule BotArmyLlm.Http.OllamaAnthropicSseStream do
  @moduledoc false

  # Streams Ollama /api/chat NDJSON (stream: true) to the client as Anthropic-style SSE.

  require Logger

  alias BotArmyLlm.AnthropicOllamaAdapter

  @receive_timeout 120_000

  @spec run(Plug.Conn.t(), map(), String.t(), String.t(), integer()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def run(conn, anthropic_body, source, event_id, start_ms) when is_map(anthropic_body) do
    model =
      System.get_env("OLLAMA_MODEL_CLAUDE_FALLBACK") ||
        System.get_env("OLLAMA_MODEL_MEDIUM", "ministral-3:8b")

    with {:ok, messages} <- AnthropicOllamaAdapter.to_ollama_messages(anthropic_body),
         {:ok, {url, _}} <- BotArmyLlm.OllamaHealthChecker.best_ollama_node(:medium),
         {:ok, json} <- Jason.encode(build_body(model, messages, anthropic_body)) do
      req =
        Finch.build(:post, "#{String.trim_trailing(url, "/")}/api/chat", [{"content-type", "application/json"}], json)

      msg_id = "msg-ollama-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

      acc0 = %{
        phase: :need_status,
        buf: "",
        prev_text: "",
        msg_id: msg_id,
        model: model,
        started: false,
        source: source,
        event_id: event_id,
        start_ms: start_ms,
        last_usage: {nil, nil}
      }

      case Finch.stream_while(
             req,
             BotArmyLlm.Finch,
             {conn, acc0},
             &stream_o_chunk/2,
             receive_timeout: @receive_timeout,
             request_timeout: @receive_timeout
           ) do
        {:ok, {:upstream_failed, status, _conn}} ->
          {:error, {:http_error, status}}

        {:ok, {:stream_failed, conn}} ->
          if conn.state == :chunked do
            {:ok, conn}
          else
            {:error, :ollama_stream_failed}
          end

        {:ok, {conn, acc}} ->
          {tin, tout} = acc.last_usage
          latency = System.monotonic_time(:millisecond) - start_ms

          BotArmyLlm.TokenAccounting.record(%{
            "event_id" => event_id,
            "event_type" => "anthropic.messages.stream",
            "source" => source,
            "provider" => "ollama",
            "model" => model,
            "tokens_input" => tin,
            "tokens_output" => tout,
            "latency_ms" => latency
          })

          Logger.info("http_proxy Ollama SSE stream done",
            source: source,
            model: model,
            latency_ms: latency
          )

          {:ok, conn}

        {:error, exception, {conn, _acc}} ->
          Logger.error("Ollama SSE stream failed: #{Exception.message(exception)}")

          if conn.state == :chunked do
            {:ok, conn}
          else
            {:error, {:stream_exception, exception}}
          end
      end
    else
      {:error, reason} ->
        Logger.debug("Ollama SSE stream unavailable: #{inspect(reason)}")
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp build_body(model, messages, anthropic_body) do
    base = %{"model" => model, "messages" => messages, "stream" => true}

    base =
      case Map.get(anthropic_body, "temperature") do
        t when is_number(t) -> put_opt(base, %{"temperature" => t})
        _ -> base
      end

    base =
      case Map.get(anthropic_body, "max_tokens") do
        n when is_integer(n) and n > 0 -> put_opt(base, %{"num_predict" => n})
        _ -> base
      end

    base
  end

  defp put_opt(%{"options" => o} = m, extra), do: %{m | "options" => Map.merge(o, extra)}
  defp put_opt(m, extra), do: Map.put(m, "options", extra)

  defp stream_o_chunk({:status, 200}, {conn, acc}) when acc.phase == :need_status do
    {:cont, {conn, %{acc | phase: :need_headers}}}
  end

  defp stream_o_chunk({:status, status}, {conn, acc}) when acc.phase == :need_status do
    {:halt, {:upstream_failed, status, conn}}
  end

  defp stream_o_chunk({:headers, _}, {conn, acc}) when acc.phase == :need_headers do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> Plug.Conn.put_resp_header("pragma", "no-cache")
      |> Plug.Conn.send_chunked(200)

    {:cont, {conn, %{acc | phase: :streaming}}}
  end

  defp stream_o_chunk({:data, data}, {conn, acc}) when acc.phase == :streaming do
    buf = acc.buf <> data
    {lines, rest} = take_complete_lines(buf)
    acc = %{acc | buf: rest}

    case emit_lines(conn, acc, lines) do
      {:ok, conn, acc} -> {:cont, {conn, acc}}
      {:error, _} -> {:halt, {:stream_failed, conn}}
    end
  end

  defp stream_o_chunk({:trailers, _}, {conn, acc}), do: {:cont, {conn, acc}}

  defp take_complete_lines(buf) do
    ends_nl = String.ends_with?(buf, "\n")
    parts = String.split(buf, "\n", trim: false)

    cond do
      parts == [""] ->
        {[], ""}

      ends_nl ->
        {Enum.drop(parts, -1), ""}

      true ->
        case parts do
          [single] ->
            {[], single}

          multi ->
            incomplete = List.last(multi)
            complete = Enum.take(multi, length(multi) - 1)
            {complete, incomplete}
        end
    end
  end

  defp emit_lines(conn, acc, lines) do
    Enum.reduce_while(lines, {:ok, conn, acc}, fn line, {:ok, conn, acc} ->
      line = String.trim(line)

      if line == "" do
        {:cont, {:ok, conn, acc}}
      else
        case Jason.decode(line) do
          {:ok, obj} ->
            case emit_for_json(conn, acc, obj) do
              {:ok, conn, acc} -> {:cont, {:ok, conn, acc}}
              {:error, _} = err -> {:halt, err}
            end

          _ ->
            {:cont, {:ok, conn, acc}}
        end
      end
    end)
  end

  defp emit_for_json(conn, acc, obj) do
    full = get_in(obj, ["message", "content"]) || ""
    tin = obj["prompt_eval_count"]
    tout = obj["eval_count"]
    acc = put_usage(acc, tin, tout)

    prev = acc.prev_text

    delta =
      if prev != "" and String.starts_with?(full, prev) do
        String.slice(full, String.length(prev)..-1//1)
      else
        full
      end

    acc = %{acc | prev_text: full}

    with {:ok, conn, acc} <- maybe_start_events(conn, acc),
         {:ok, conn, acc} <- emit_delta_chunk(conn, acc, delta) do
      if obj["done"] == true do
        case emit_done(conn, acc) do
          {:ok, conn} -> {:ok, conn, acc}
          {:error, _} = err -> err
        end
      else
        {:ok, conn, acc}
      end
    end
  end

  defp put_usage(acc, tin, tout) do
    u =
      case {tin, tout} do
        {nil, nil} -> acc.last_usage
        _ -> {tin, tout}
      end

    %{acc | last_usage: u}
  end

  defp maybe_start_events(conn, %{started: true} = acc), do: {:ok, conn, acc}

  defp maybe_start_events(conn, acc) do
    m = acc.msg_id

    sse1 =
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => m,
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => acc.model,
          "stop_reason" => nil,
          "stop_sequence" => nil
        }
      })

    sse2 =
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      })

    case chunk(conn, sse1 <> sse2) do
      {:ok, conn} -> {:ok, conn, %{acc | started: true}}
      {:error, _} = err -> err
    end
  end

  defp emit_delta_chunk(conn, acc, ""), do: {:ok, conn, acc}

  defp emit_delta_chunk(conn, acc, text) do
    ev =
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      })

    case chunk(conn, ev) do
      {:ok, conn} -> {:ok, conn, acc}
      {:error, _} = err -> err
    end
  end

  defp emit_done(conn, acc) do
    {tin, tout} = acc.last_usage

    sse1 =
      sse("content_block_stop", %{
        "type" => "content_block_stop",
        "index" => 0
      })

    sse2 =
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"input_tokens" => tin || 0, "output_tokens" => tout || 0}
      })

    sse3 = sse("message_stop", %{"type" => "message_stop"})
    chunk(conn, sse1 <> sse2 <> sse3)
  end

  defp chunk(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} = err -> err
    end
  end

  defp sse(event, data) do
    "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end
end
