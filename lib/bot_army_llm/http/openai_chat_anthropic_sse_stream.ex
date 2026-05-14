defmodule BotArmyLlm.Http.OpenaiChatAnthropicSseStream do
  @moduledoc false
  # OpenAI-compatible chat completions (stream: true) → Anthropic-shaped SSE for the client.

  require Logger

  alias BotArmyLlm.AnthropicMessagesToOpenaiChat

  @receive_timeout 120_000

  @spec run(Plug.Conn.t(), map(), keyword()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def run(conn, anthropic_payload, opts) when is_map(anthropic_payload) and is_list(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    url = Keyword.fetch!(opts, :url)
    model = Keyword.fetch!(opts, :model)
    extra_headers = Keyword.get(opts, :extra_headers, [])
    source = Keyword.fetch!(opts, :source)
    event_id = Keyword.fetch!(opts, :event_id)
    start_ms = Keyword.fetch!(opts, :start_ms)
    provider = Keyword.fetch!(opts, :provider)

    with {:ok, %{messages: messages, tools: tools}} <-
           AnthropicMessagesToOpenaiChat.to_chat_completion_request(anthropic_payload),
         {:ok, body_map} <- build_stream_request(messages, tools, anthropic_payload, model),
         {:ok, json} <- Jason.encode(body_map) do
      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{api_key}"} | extra_headers
      ]

      req = Finch.build(:post, url, headers, json)

      msg_id =
        "msg-#{provider}-" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))

      acc0 = %{
        phase: :need_status,
        upstream_sse_buf: "",
        source: source,
        event_id: event_id,
        start_ms: start_ms,
        model: model,
        provider: provider,
        msg_id: msg_id,
        client_started: false,
        message_started: false,
        text_block_started: false,
        anthropic_closed: false,
        tool_merge: %{},
        finish_reason: nil,
        last_usage: {nil, nil}
      }

      case Finch.stream_while(
             req,
             BotArmyLlm.Finch,
             {conn, acc0},
             &stream_finch/2,
             receive_timeout: @receive_timeout,
             request_timeout: @receive_timeout
           ) do
        {:ok, {:upstream_failed, status, _conn}} ->
          {:error, {:http_error, status}}

        {:ok, {:sse_process_error, reason}} ->
          {:error, {:sse_process_error, reason}}

        {:ok, {conn, acc}} ->
          {conn, acc} = finalize_upstream(conn, acc)

          if acc.client_started do
            latency = System.monotonic_time(:millisecond) - start_ms
            {tin, tout} = acc.last_usage

            BotArmyLlm.TokenAccounting.record(%{
              "event_id" => event_id,
              "event_type" => "anthropic.messages.stream",
              "source" => source,
              "provider" => to_string(provider),
              "model" => model,
              "tokens_input" => tin,
              "tokens_output" => tout,
              "latency_ms" => latency
            })

            Logger.info("http_proxy OpenAI-compat stream done",
              source: source,
              provider: provider,
              model: model,
              latency_ms: latency
            )

            {:ok, conn}
          else
            {:error, {:openai_stream_no_body, provider}}
          end

        {:error, exception, {conn, _acc}} ->
          Logger.error(
            "http_proxy OpenAI-compat stream transport: #{Exception.message(exception)}"
          )

          {:error, {:stream_exception, exception, conn}}

        other ->
          Logger.error("http_proxy OpenAI-compat unexpected: #{inspect(other)}")
          {:error, {:unexpected_result, other}}
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :bad_request}
    end
  end

  defp build_stream_request(messages, tools, anthropic_payload, model) do
    body = %{"model" => model, "messages" => messages, "stream" => true}

    body =
      case tools do
        [] -> body
        list when is_list(list) -> Map.put(body, "tools", list)
      end

    body =
      case Map.get(anthropic_payload, "temperature") do
        t when is_number(t) -> Map.put(body, "temperature", t)
        _ -> body
      end

    body =
      case Map.get(anthropic_payload, "max_tokens") do
        n when is_integer(n) and n > 0 -> Map.put(body, "max_tokens", n)
        _ -> body
      end

    {:ok, body}
  end

  defp stream_finch({:status, status}, {conn, acc}) when acc.phase == :need_status do
    if status == 200 do
      {:cont, {conn, %{acc | phase: :need_headers}}}
    else
      {:halt, {:upstream_failed, status, conn}}
    end
  end

  defp stream_finch({:headers, _}, {conn, acc}) when acc.phase == :need_headers do
    {:cont, {conn, %{acc | phase: :body}}}
  end

  defp stream_finch({:data, data}, {conn, acc}) when acc.phase == :body do
    acc = %{acc | upstream_sse_buf: acc.upstream_sse_buf <> data}

    case process_sse_buffer(conn, acc) do
      {:ok, conn, acc} -> {:cont, {conn, acc}}
      {:error, reason} -> {:halt, {:sse_process_error, reason}}
    end
  end

  defp stream_finch({:trailers, _}, acc), do: {:cont, acc}

  defp stream_finch(other, acc) do
    Logger.warning("http_proxy OpenAI-compat finch chunk: #{inspect(other)}")
    {:cont, acc}
  end

  defp process_sse_buffer(conn, acc) do
    {frames, rest} = take_sse_frames(acc.upstream_sse_buf)
    acc = %{acc | upstream_sse_buf: rest}

    case Enum.reduce_while(frames, {:ok, conn, acc}, fn frame, {:ok, conn, acc} ->
           case handle_sse_frame(conn, acc, frame) do
             {:ok, conn, acc} -> {:cont, {:ok, conn, acc}}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      {:ok, conn, acc} -> {:ok, conn, acc}
      {:error, _} = err -> err
    end
  end

  defp take_sse_frames(buf) do
    cond do
      buf == "" ->
        {[], ""}

      String.ends_with?(buf, "\n\n") ->
        core = String.trim_trailing(buf, "\n\n")
        parts = if core == "", do: [], else: String.split(core, "\n\n", trim: false)
        {parts, ""}

      true ->
        parts = String.split(buf, "\n\n", trim: false)

        case parts do
          [] ->
            {[], ""}

          [_single] ->
            {[], buf}

          _ ->
            rest = List.last(parts)
            complete = Enum.drop(parts, -1)
            {complete, rest}
        end
    end
  end

  defp handle_sse_frame(conn, acc, frame) do
    payload = collect_data_lines(frame)

    if payload == "" or payload == "[DONE]" do
      {conn, acc} =
        if payload == "[DONE]", do: close_anthropic_stream_impl(conn, acc), else: {conn, acc}

      {:ok, conn, acc}
    else
      case Jason.decode(payload) do
        {:ok, obj} ->
          acc = merge_usage_from_chunk(acc, obj)

          choice = List.first(obj["choices"] || []) || %{}
          delta = Map.get(choice, "delta") || %{}
          content = Map.get(delta, "content")
          finish = Map.get(choice, "finish_reason")
          acc = merge_tool_deltas(acc, Map.get(delta, "tool_calls"))

          acc =
            if finish not in [nil, ""] do
              %{acc | finish_reason: finish}
            else
              acc
            end

          case maybe_emit_text_delta(conn, acc, content) do
            {:ok, conn, acc} -> {:ok, conn, acc}
            {:error, _} = err -> err
          end

        {:error, _} ->
          {:ok, conn, acc}
      end
    end
  end

  defp collect_data_lines(frame) do
    frame
    |> String.split("\n", trim: false)
    |> Enum.reduce([], fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" ->
          acc

        String.starts_with?(line, "data:") ->
          rest =
            if String.starts_with?(line, "data: ") do
              String.slice(line, 6..-1//1)
            else
              String.slice(line, 5..-1//1) |> String.trim_leading()
            end

          if rest != "", do: [rest | acc], else: acc

        true ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp merge_tool_deltas(acc, nil), do: acc

  defp merge_tool_deltas(acc, patches) when is_list(patches) do
    merge =
      Enum.reduce(patches, acc.tool_merge, fn patch, tm ->
        idx = Map.get(patch, "index")
        idx = if is_integer(idx), do: idx, else: 0

        cur = Map.get(tm, idx, %{"id" => nil, "name" => nil, "arguments" => ""})
        id = Map.get(patch, "id") || cur["id"]
        fn_p = Map.get(patch, "function") || %{}
        name = Map.get(fn_p, "name") || cur["name"]
        frag = Map.get(fn_p, "arguments") || ""
        args = cur["arguments"] <> frag
        Map.put(tm, idx, %{"id" => id, "name" => name, "arguments" => args})
      end)

    %{acc | tool_merge: merge}
  end

  defp merge_tool_deltas(acc, _), do: acc

  defp merge_usage_from_chunk(acc, obj) do
    case Map.get(obj, "usage") do
      %{"prompt_tokens" => pt, "completion_tokens" => ct} ->
        %{acc | last_usage: {pt, ct}}

      %{"prompt_tokens" => pt} ->
        {_, ct} = acc.last_usage
        %{acc | last_usage: {pt, ct || 0}}

      _ ->
        acc
    end
  end

  defp maybe_emit_text_delta(conn, acc, content) when content in [nil, ""] do
    {:ok, conn, acc}
  end

  defp maybe_emit_text_delta(conn, acc, content) when is_binary(content) do
    with {:ok, conn, acc} <- ensure_client_stream(conn, acc),
         {:ok, conn, acc} <- ensure_message_start(conn, acc),
         {:ok, conn, acc} <- ensure_text_block(conn, acc),
         {:ok, conn} <- chunk(conn, sse_text_delta(0, content)) do
      {:ok, conn, %{acc | text_block_started: true}}
    else
      {:error, _} = e -> e
      _ -> {:error, :chunk_failed}
    end
  end

  defp ensure_client_stream(conn, %{client_started: true} = acc), do: {:ok, conn, acc}

  defp ensure_client_stream(conn, acc) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> Plug.Conn.put_resp_header("pragma", "no-cache")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn, %{acc | client_started: true}}
  end

  defp ensure_message_start(conn, %{message_started: true} = acc), do: {:ok, conn, acc}

  defp ensure_message_start(conn, acc) do
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

    with {:ok, conn} <- chunk(conn, sse1) do
      {:ok, conn, %{acc | message_started: true}}
    end
  end

  defp ensure_text_block(conn, %{text_block_started: true} = acc), do: {:ok, conn, acc}

  defp ensure_text_block(conn, acc) do
    sse2 =
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      })

    with {:ok, conn} <- chunk(conn, sse2) do
      {:ok, conn, %{acc | text_block_started: true}}
    end
  end

  defp sse_text_delta(index, text) do
    sse("content_block_delta", %{
      "type" => "content_block_delta",
      "index" => index,
      "delta" => %{"type" => "text_delta", "text" => text}
    })
  end

  defp close_anthropic_stream_impl(conn, %{anthropic_closed: true} = acc), do: {conn, acc}

  defp close_anthropic_stream_impl(conn, %{client_started: false} = acc) do
    {conn, %{acc | anthropic_closed: true}}
  end

  defp close_anthropic_stream_impl(conn, acc) do
    tools_sorted =
      acc.tool_merge
      |> Map.to_list()
      |> Enum.sort_by(fn {i, _} -> i end)

    has_tools = tools_sorted != []

    with {:ok, conn, acc} <- ensure_ready_for_close(conn, acc, has_tools),
         {:ok, conn, acc} <- close_content_blocks(conn, acc, tools_sorted, has_tools),
         {:ok, conn} <- emit_message_end(conn, acc, has_tools) do
      {conn, %{acc | anthropic_closed: true}}
    else
      {:error, _} -> {conn, %{acc | anthropic_closed: true}}
    end
  end

  defp ensure_ready_for_close(conn, acc, has_tools) do
    cond do
      has_tools && !acc.message_started ->
        with {:ok, conn, acc} <- ensure_client_stream(conn, acc) do
          ensure_message_start(conn, acc)
        end

      acc.message_started || has_tools ->
        {:ok, conn, acc}

      true ->
        {:ok, conn, acc}
    end
  end

  defp close_content_blocks(conn, acc, tools_sorted, has_tools) do
    cond do
      has_tools && acc.text_block_started ->
        with {:ok, conn} <- chunk(conn, sse_content_block_stop(0)) do
          emit_tool_blocks(conn, acc, 1, tools_sorted)
        end

      has_tools ->
        emit_tool_blocks(conn, acc, 0, tools_sorted)

      acc.text_block_started ->
        case chunk(conn, sse_content_block_stop(0)) do
          {:ok, conn} -> {:ok, conn, acc}
          {:error, _} = e -> e
        end

      true ->
        {:ok, conn, acc}
    end
  end

  defp emit_tool_blocks(conn, acc, start_idx, sorted_tools) do
    Enum.reduce_while(Enum.with_index(sorted_tools), {:ok, conn, acc}, fn {{_i, t}, pos},
                                                                          {:ok, conn, acc} ->
      anthropic_idx = start_idx + pos
      id = t["id"] || "call_unknown"
      name = t["name"] || ""
      args = t["arguments"] || "{}"

      start_ev =
        sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => anthropic_idx,
          "content_block" => %{
            "type" => "tool_use",
            "id" => id,
            "name" => name,
            "input" => %{}
          }
        })

      delta_ev =
        sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => anthropic_idx,
          "delta" => %{"type" => "input_json_delta", "partial_json" => args}
        })

      stop_ev =
        sse("content_block_stop", %{
          "type" => "content_block_stop",
          "index" => anthropic_idx
        })

      case chunk(conn, start_ev <> delta_ev <> stop_ev) do
        {:ok, conn} -> {:cont, {:ok, conn, acc}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp sse_content_block_stop(index) do
    sse("content_block_stop", %{"type" => "content_block_stop", "index" => index})
  end

  defp emit_message_end(conn, acc, has_tools) do
    {tin, tout} = acc.last_usage

    stop =
      if has_tools do
        "tool_use"
      else
        stop_reason_from_finish(acc.finish_reason)
      end

    sse2 =
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop, "stop_sequence" => nil},
        "usage" => %{"input_tokens" => tin || 0, "output_tokens" => tout || 0}
      })

    sse3 = sse("message_stop", %{"type" => "message_stop"})
    chunk(conn, sse2 <> sse3)
  end

  defp stop_reason_from_finish(nil), do: "end_turn"
  defp stop_reason_from_finish(""), do: "end_turn"
  defp stop_reason_from_finish("stop"), do: "end_turn"
  defp stop_reason_from_finish("tool_calls"), do: "tool_use"
  defp stop_reason_from_finish(other) when is_binary(other), do: other
  defp stop_reason_from_finish(_), do: "end_turn"

  defp finalize_upstream(conn, acc) do
    if acc.client_started && !acc.anthropic_closed do
      close_anthropic_stream_impl(conn, acc)
    else
      {conn, acc}
    end
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
