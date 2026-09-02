defmodule BotArmyLlm.Proxy.StreamManager do
  @moduledoc """
  Coordinates the end-to-end streaming process for LLM proxy requests.
  Handles the transport-level SSE chunking and delivery.
  """

  require Logger
  alias BotArmyLlm.Proxy.Adapter

  @doc """
  Proxies a streaming request.
  `conn` is the Plug connection.
  `body` is the request payload.
  `source` is the request source (e.g., "claude_code").
  """
  def proxy_stream(conn, body, source) do
    # 1. Translate the request to the target provider (default Anthropic)
    translated_body = Adapter.translate_request(body, source)

    # 2. Determine the backend provider based on config or payload
    provider = determine_provider(translated_body)

    # 3. Connect to the provider's stream and pipe it through the adapter
    case connect_to_provider_stream(provider, translated_body) do
      {:ok, stream} ->
        # Set SSE headers
        conn = 
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
          |> Plug.Conn.put_resp_header("pragma", "no-cache")
          |> Plug.Conn.send_chunked(200)

        # Stream the response
        pipe_stream(conn, stream, provider)

      {:error, reason} ->
        Logger.error("Failed to connect to provider stream: #{inspect(reason)}")
        handle_stream_error(conn, reason)
    end
  end

  defp determine_provider(body) do
    # Logic to decide if we go to Ollama, OpenAI, or Anthropic direct
    # This can be based on the 'model' field in the body
    "anthropic"
  end

  defp connect_to_provider_stream(provider, body) do
    # Logic to initiate the HTTP request to the provider
    # This will eventually replace the specialized SSEStream modules
    {:error, :not_implemented_yet}
  end

  defp pipe_stream(conn, stream, provider) do
    # Logic to read from the provider stream, translate the chunk, and send it
    # Each chunk is translated via Adapter.translate_response/3
    # and then sent via Plug.Conn.send_chunk/2
    :ok
  end

  defp handle_stream_error(conn, reason) do
    # Standardized error response for streams
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"type" => "stream_error", "message" => inspect(reason)}}))
  end
end
