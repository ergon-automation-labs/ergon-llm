defmodule BotArmyLlm.ClaudePassthroughStream do
  @moduledoc false
  # Walks the same provider chain as `ClaudePassthroughChain` for `stream: true` requests.

  require Logger

  alias BotArmyLlm.ClaudePassthroughChain
  alias BotArmyLlm.Http.{AnthropicNativeSseStream, OpenaiChatAnthropicSseStream, OllamaAnthropicSseStream}

  @spec run(Plug.Conn.t(), map(), String.t(), String.t(), integer()) :: Plug.Conn.t()
  def run(conn, body, source, event_id, start_ms) when is_map(body) do
    case ClaudePassthroughChain.stream_chain_steps() do
      {:error, reason} ->
        chain_parse_error(conn, reason)

      {:ok, steps} ->
        run_steps(steps, conn, body, source, event_id, start_ms, nil)
    end
  end

  defp chain_parse_error(conn, {:unknown_claude_chain_step, word}) do
    json_error(conn, 500, "invalid_configuration", "Unknown Claude chain step: #{word}")
  end

  defp chain_parse_error(conn, reason) do
    json_error(conn, 500, "invalid_configuration", inspect(reason))
  end

  defp run_steps([], conn, _body, source, _event_id, _start_ms, last_err) do
    case conn.state do
      s when s in [:chunked, :sent] ->
        conn

      _ ->
        Logger.error("http_proxy streaming chain exhausted",
          source: source,
          last_error: inspect(last_err)
        )

        json_error(conn, 502, "upstream_error", "LLM proxy error: #{inspect(last_err)}")
    end
  end

  defp run_steps([step | rest], conn, body, source, event_id, start_ms, _prev_err) do
    case dispatch(step, conn, body, source, event_id, start_ms) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        conn = prefer_error_conn(reason, conn)

        if conn.state in [:chunked, :sent] do
          conn
        else
          Logger.debug("http_proxy streaming step #{step} failed: #{inspect(reason)}")
          run_steps(rest, conn, body, source, event_id, start_ms, reason)
        end
    end
  end

  defp prefer_error_conn({:stream_exception, _ex, conn}, _fallback), do: conn
  defp prefer_error_conn({:stream_exception, _ex}, fallback), do: fallback
  defp prefer_error_conn(_reason, fallback), do: fallback

  defp dispatch(:blackbox, conn, body, source, event_id, start_ms) do
    api_key = System.get_env("BLACKBOX_API_KEY")
    url = System.get_env("BLACKBOX_BASE_URL", "https://api.blackbox.ai/api/chat")

    model =
      System.get_env("BLACKBOX_MODEL_CLAUDE_CODE") ||
        System.get_env("BLACKBOX_MODEL_MEDIUM", "qwen/qwen3-32b:free")

    case api_key do
      nil ->
        {:error, {:provider_not_configured, "Blackbox"}}

      "" ->
        {:error, {:model_not_configured, "Blackbox"}}

      key ->
        OpenaiChatAnthropicSseStream.run(conn, body,
          api_key: key,
          url: url,
          model: model,
          extra_headers: [],
          source: source,
          event_id: event_id,
          start_ms: start_ms,
          provider: :blackbox
        )
    end
  end

  defp dispatch(:openrouter, conn, body, source, event_id, start_ms) do
    api_key = System.get_env("OPENROUTER_API_KEY")
    url = System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1/chat/completions")
    model = System.get_env("OPENROUTER_MODEL_CLAUDE_CODE", "anthropic/claude-3.5-sonnet")
    extra = [{"HTTP-Referer", "https://github.com/ergon-automation-labs"}]

    case api_key do
      nil ->
        {:error, {:provider_not_configured, "OpenRouter"}}

      "" ->
        {:error, {:model_not_configured, "OpenRouter"}}

      key ->
        OpenaiChatAnthropicSseStream.run(conn, body,
          api_key: key,
          url: url,
          model: model,
          extra_headers: extra,
          source: source,
          event_id: event_id,
          start_ms: start_ms,
          provider: :openrouter
        )
    end
  end

  defp dispatch(:anthropic, conn, body, source, event_id, start_ms) do
    AnthropicNativeSseStream.run(conn, body, source, event_id, start_ms)
  end

  defp dispatch(:ollama, conn, body, source, event_id, start_ms) do
    OllamaAnthropicSseStream.run(conn, body, source, event_id, start_ms)
  end

  defp json_error(conn, status, type, message) do
    body = Jason.encode!(%{"error" => %{"type" => type, "message" => message}})

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(status, body)
  end
end
