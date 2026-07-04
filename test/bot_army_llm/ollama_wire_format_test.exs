defmodule BotArmyLlm.OllamaWireFormatTest do
  use ExUnit.Case, async: true
  @moduletag :client

  import ExUnit.CaptureLog

  alias BotArmyLlm.{HttpFallback, LlmClient, OllamaWireFormat}

  # Force ollama-only routing so LlmClient.complete/2 exercises the ollama call
  # path without touching real cloud providers. The health checker is stubbed to
  # point at the test's :gen_tcp servers.
  setup do
    prev_chain = Application.get_env(:bot_army_llm, :provider_chain)
    prev_hc = Application.get_env(:bot_army_llm, :ollama_health_checker)

    Application.put_env(:bot_army_llm, :provider_chain, [:ollama])
    Application.put_env(:bot_army_llm, :ollama_health_checker, __MODULE__.StubChecker)

    on_exit(fn ->
      if prev_chain == nil do
        Application.delete_env(:bot_army_llm, :provider_chain)
      else
        Application.put_env(:bot_army_llm, :provider_chain, prev_chain)
      end

      if prev_hc == nil do
        Application.delete_env(:bot_army_llm, :ollama_health_checker)
      else
        Application.put_env(:bot_army_llm, :ollama_health_checker, prev_hc)
      end
    end)

    :ok
  end

  defmodule StubChecker do
    @moduledoc false
    # Returns the native ollama URL the test wired via env. The openai branch uses
    # OLLAMA_CHAT_URL for headroom and falls back to this native URL.
    def best_ollama_node(_complexity) do
      {:ok, {System.get_env("OLLAMA_URL", "http://127.0.0.1:0"), "test-model"}}
    end

    # provider_chain/1 calls this before routing to ollama; stub fail-open.
    def load_acceptable?, do: true
  end

  # --- wire_format/0 ---

  test "wire_format defaults to :native when OLLAMA_WIRE_FORMAT unset" do
    System.delete_env("OLLAMA_WIRE_FORMAT")
    assert OllamaWireFormat.wire_format() == :native
  end

  test "wire_format returns :openai when OLLAMA_WIRE_FORMAT=openai" do
    System.put_env("OLLAMA_WIRE_FORMAT", "openai")
    assert OllamaWireFormat.wire_format() == :openai
  after
    System.delete_env("OLLAMA_WIRE_FORMAT")
  end

  test "wire_format is case-insensitive" do
    System.put_env("OLLAMA_WIRE_FORMAT", "OpenAI")
    assert OllamaWireFormat.wire_format() == :openai
  after
    System.delete_env("OLLAMA_WIRE_FORMAT")
  end

  test "wire_format falls back to :native on a bad value" do
    System.put_env("OLLAMA_WIRE_FORMAT", "xml")
    assert OllamaWireFormat.wire_format() == :native
  after
    System.delete_env("OLLAMA_WIRE_FORMAT")
  end

  # --- chat_url/0 + ollama_url/0 ---

  test "chat_url uses OLLAMA_CHAT_URL when set" do
    System.put_env("OLLAMA_CHAT_URL", "http://127.0.0.1:8790")
    assert OllamaWireFormat.chat_url() == "http://127.0.0.1:8790"
  after
    System.delete_env("OLLAMA_CHAT_URL")
  end

  test "chat_url defaults to OLLAMA_URL when OLLAMA_CHAT_URL unset" do
    System.delete_env("OLLAMA_CHAT_URL")
    System.put_env("OLLAMA_URL", "http://127.0.0.1:11434")
    assert OllamaWireFormat.chat_url() == "http://127.0.0.1:11434"
  after
    System.delete_env("OLLAMA_URL")
  end

  test "chat_url defaults to localhost:11434 when both unset" do
    System.delete_env("OLLAMA_CHAT_URL")
    System.delete_env("OLLAMA_URL")
    assert OllamaWireFormat.chat_url() == "http://localhost:11434"
  end

  test "ollama_url uses OLLAMA_URL when set" do
    System.put_env("OLLAMA_URL", "http://127.0.0.1:11434")
    assert OllamaWireFormat.ollama_url() == "http://127.0.0.1:11434"
  after
    System.delete_env("OLLAMA_URL")
  end

  # --- HttpFallback.down?/1 ---

  test "down? is false for 2xx and 4xx" do
    refute HttpFallback.down?({:ok, %HTTPoison.Response{status_code: 200, body: ""}})
    refute HttpFallback.down?({:ok, %HTTPoison.Response{status_code: 404, body: ""}})
  end

  test "down? is true for 5xx" do
    assert HttpFallback.down?({:ok, %HTTPoison.Response{status_code: 503, body: ""}})
    assert HttpFallback.down?({:ok, %HTTPoison.Response{status_code: 500, body: ""}})
  end

  test "down? is true for connection errors" do
    assert HttpFallback.down?({:error, %HTTPoison.Error{reason: :econnrefused}})
  end

  test "down? is false for unexpected shapes" do
    refute HttpFallback.down?(:unexpected)
  end

  # --- integration through LlmClient.complete/2 ---
  # Exercises the private ollama_call/3 wire-format branch end-to-end via the
  # public client API, using local :gen_tcp servers as headroom (openai) and
  # native ollama endpoints.

  defp start_server(handler) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
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

  defp openai_200(sock) do
    body =
      Jason.encode!(%{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "openai-reply"}}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
      })

    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
    )
  end

  defp native_200(sock) do
    body =
      Jason.encode!(%{
        "message" => %{"role" => "assistant", "content" => "native-reply"},
        "eval_count" => 3,
        "prompt_eval_count" => 2
      })

    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
    )
  end

  defp http_503(sock) do
    :gen_tcp.send(
      sock,
      "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    )
  end

  test "openai wire format routes through headroom /v1/chat/completions" do
    {headroom_port, _} = start_server(&openai_200/1)
    {native_port, _} = start_server(&native_200/1)

    System.put_env("OLLAMA_WIRE_FORMAT", "openai")
    System.put_env("OLLAMA_CHAT_URL", "http://127.0.0.1:#{headroom_port}")
    System.put_env("OLLAMA_URL", "http://127.0.0.1:#{native_port}")

    assert {:ok, %{completion: "openai-reply"}} = LlmClient.complete("hello")
  after
    System.delete_env("OLLAMA_WIRE_FORMAT")
    System.delete_env("OLLAMA_CHAT_URL")
    System.delete_env("OLLAMA_URL")
  end

  test "openai branch falls back to native ollama on 5xx from headroom" do
    {headroom_port, _} = start_server(&http_503/1)
    {native_port, _} = start_server(&native_200/1)

    System.put_env("OLLAMA_WIRE_FORMAT", "openai")
    System.put_env("OLLAMA_CHAT_URL", "http://127.0.0.1:#{headroom_port}")
    System.put_env("OLLAMA_URL", "http://127.0.0.1:#{native_port}")

    log =
      capture_log(fn ->
        assert {:ok, %{completion: "native-reply"}} = LlmClient.complete("hello")
      end)

    assert log =~ "[headroom-down]"
  after
    System.delete_env("OLLAMA_WIRE_FORMAT")
    System.delete_env("OLLAMA_CHAT_URL")
    System.delete_env("OLLAMA_URL")
  end

  test "openai branch falls back to native ollama when headroom unreachable" do
    # Bind + immediately close a port to get a dead port number (econnrefused).
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, dead_port} = :inet.port(lsock)
    :gen_tcp.close(lsock)

    {native_port, _} = start_server(&native_200/1)

    System.put_env("OLLAMA_WIRE_FORMAT", "openai")
    System.put_env("OLLAMA_CHAT_URL", "http://127.0.0.1:#{dead_port}")
    System.put_env("OLLAMA_URL", "http://127.0.0.1:#{native_port}")

    log =
      capture_log(fn ->
        assert {:ok, %{completion: "native-reply"}} = LlmClient.complete("hello")
      end)

    assert log =~ "[headroom-down]"
  after
    System.delete_env("OLLAMA_WIRE_FORMAT")
    System.delete_env("OLLAMA_CHAT_URL")
    System.delete_env("OLLAMA_URL")
  end

  test "native wire format uses /api/chat directly (no headroom)" do
    {native_port, _} = start_server(&native_200/1)

    System.delete_env("OLLAMA_WIRE_FORMAT")
    System.put_env("OLLAMA_URL", "http://127.0.0.1:#{native_port}")

    assert {:ok, %{completion: "native-reply"}} = LlmClient.complete("hello")
  after
    System.delete_env("OLLAMA_URL")
  end
end
