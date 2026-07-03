defmodule BotArmyLlm.HttpFallbackTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.HttpFallback

  # Minimal local HTTP server on an ephemeral port. The owning process keeps
  # the listen socket alive and accepts connections in a loop; `handler` writes
  # a full HTTP response per connection. No new test deps required.
  defp start_server(handler) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lsock} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(lsock)
        send(parent, {:port, port})
        loop_accept(lsock, handler)
      end)

    receive do
      {:port, port} -> {port, pid}
    after
      1_000 -> flunk("server did not start")
    end
  end

  defp loop_accept(lsock, handler) do
    case :gen_tcp.accept(lsock, 10_000) do
      {:ok, sock} ->
        :gen_tcp.recv(sock, 0, 500)
        handler.(sock)
        :gen_tcp.close(sock)
        loop_accept(lsock, handler)

      {:error, :timeout} ->
        :ok
    end
  end

  defp http_200(sock, body \\ "ok") do
    resp =
      "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

    :gen_tcp.send(sock, resp)
  end

  defp http_503(sock) do
    resp = "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    :gen_tcp.send(sock, resp)
  end

  test "primary 200 returns directly when fallback differs" do
    {port, _} = start_server(&http_200/1)

    {:ok, resp} =
      HttpFallback.post_with_fallback(
        "http://127.0.0.1:#{port}",
        "https://api.anthropic.com/v1/messages",
        "body",
        [{"content-type", "application/json"}],
        recv_timeout: 3_000
      )

    assert %HTTPoison.Response{status_code: 200} = resp
  end

  test "primary 5xx falls back to a healthy fallback URL" do
    {bad_port, _} = start_server(&http_503/1)
    {good_port, _} = start_server(&http_200/1)

    {:ok, resp} =
      HttpFallback.post_with_fallback(
        "http://127.0.0.1:#{bad_port}",
        "http://127.0.0.1:#{good_port}",
        "body",
        [{"content-type", "application/json"}],
        recv_timeout: 3_000
      )

    assert %HTTPoison.Response{status_code: 200} = resp
  end

  test "primary unreachable (econnrefused) falls back to fallback URL" do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, dead_port} = :inet.port(lsock)
    :gen_tcp.close(lsock)

    {good_port, _} = start_server(&http_200/1)

    {:ok, resp} =
      HttpFallback.post_with_fallback(
        "http://127.0.0.1:#{dead_port}",
        "http://127.0.0.1:#{good_port}",
        "body",
        [{"content-type", "application/json"}],
        recv_timeout: 3_000
      )

    assert %HTTPoison.Response{status_code: 200} = resp
  end

  test "url == fallback_url short-circuits to a single direct post" do
    {port, _} = start_server(&http_200/1)
    url = "http://127.0.0.1:#{port}"

    {:ok, resp} = HttpFallback.post_with_fallback(url, url, "body", [], recv_timeout: 3_000)

    assert %HTTPoison.Response{status_code: 200} = resp
  end

  test "nil fallback_url is a plain direct post" do
    {port, _} = start_server(&http_200/1)

    {:ok, resp} =
      HttpFallback.post_with_fallback("http://127.0.0.1:#{port}", nil, "body", [],
        recv_timeout: 3_000
      )

    assert %HTTPoison.Response{status_code: 200} = resp
  end
end
