defmodule BotArmyLlm.OllamaHealthChecker do
  @moduledoc """
  Background GenServer that probes configured Ollama nodes every 60 seconds.

  Uses a cheap probe request ("1+1=") with gemma3:1b to measure response latency.
  Nodes exceeding the degraded latency threshold are marked unhealthy.
  Prometheus memory pressure is checked as a secondary signal.

  ## Routing
  - best_ollama_node/1 returns the lowest-latency healthy node for :light/:medium
  - :heavy complexity always returns {:error, :skip_local} to force cloud routing

  ## Env vars
    OLLAMA_URL              - Air node Ollama URL (default: http://localhost:11434)
    OLLAMA_MINI_URL         - Mini node Ollama URL (empty = not configured)
    OLLAMA_PROBE_MODEL      - Model for health probes (default: gemma3:1b)
    OLLAMA_MODEL_LIGHT      - Model for light tasks (default: ministral-3:3b)
    OLLAMA_MODEL_MEDIUM     - Model for medium tasks (default: ministral-3:8b)
    OLLAMA_DEGRADED_LATENCY_MS - Latency threshold for healthy status (default: 8000)
  """

  use GenServer
  require Logger

  @probe_interval_ms 60_000
  @probe_timeout_ms 10_000
  @prometheus_url "http://localhost:30090"

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the best Ollama URL + model for a given complexity level.
  Returns {:ok, {url, model}} | {:error, :skip_local | :no_healthy_nodes}
  """
  @spec best_ollama_node(:light | :medium | :heavy) ::
          {:ok, {String.t(), String.t()}} | {:error, atom()}
  def best_ollama_node(:heavy), do: {:error, :skip_local}

  def best_ollama_node(complexity) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :health_checker_not_running}
      _pid -> GenServer.call(__MODULE__, {:best_node, complexity})
    end
  end

  @doc "Returns current health status of all configured nodes."
  def node_status do
    GenServer.call(__MODULE__, :node_status)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = build_initial_state()
    send(self(), :probe)
    {:ok, state}
  end

  @impl true
  def handle_info(:probe, state) do
    new_state = probe_all_nodes(state)
    Process.send_after(self(), :probe, @probe_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:best_node, complexity}, _from, state) do
    model = local_model_for(complexity)

    result =
      state.nodes
      |> Enum.filter(fn {_name, node} -> node.healthy end)
      |> Enum.sort_by(fn {_name, node} -> node.latency_ms || 999_999 end)
      |> case do
        [{_name, node} | _] -> {:ok, {node.url, model}}
        [] -> {:error, :no_healthy_nodes}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:node_status, _from, state) do
    status =
      Enum.map(state.nodes, fn {name, node} ->
        %{
          name: name,
          url: node.url,
          latency_ms: node.latency_ms,
          healthy: node.healthy,
          last_probe_at: node.last_probe_at,
          memory_pressure: node.memory_pressure
        }
      end)

    {:reply, status, state}
  end

  # Private

  defp build_initial_state do
    %{
      nodes: %{
        air: %{
          url: System.get_env("OLLAMA_URL", "http://localhost:11434"),
          latency_ms: nil,
          last_probe_at: nil,
          healthy: false,
          memory_pressure: nil
        },
        mini: %{
          url: System.get_env("OLLAMA_MINI_URL", ""),
          latency_ms: nil,
          last_probe_at: nil,
          healthy: false,
          memory_pressure: nil
        }
      },
      probe_model: System.get_env("OLLAMA_PROBE_MODEL", "gemma3:1b"),
      degraded_latency_ms:
        "OLLAMA_DEGRADED_LATENCY_MS"
        |> System.get_env("8000")
        |> String.to_integer()
    }
  end

  defp probe_all_nodes(state) do
    nodes =
      Map.new(state.nodes, fn {name, node} ->
        updated = probe_node(name, node, state.probe_model, state.degraded_latency_ms)
        {name, updated}
      end)

    %{state | nodes: nodes}
  end

  defp probe_node(_name, %{url: url} = node, _probe_model, _degraded_latency_ms)
       when url in [nil, ""] do
    %{node | healthy: false, latency_ms: nil}
  end

  defp probe_node(name, node, probe_model, degraded_latency_ms) do
    start = System.monotonic_time(:millisecond)

    case send_probe(node.url, probe_model) do
      :ok ->
        latency = System.monotonic_time(:millisecond) - start
        memory_pressure = check_memory_pressure(name)
        healthy = latency < degraded_latency_ms

        unless healthy do
          Logger.warning(
            "Ollama node #{name} probe latency #{latency}ms exceeds #{degraded_latency_ms}ms threshold"
          )
        end

        Logger.debug("Ollama node #{name} probe ok: #{latency}ms, memory=#{inspect(memory_pressure)}")

        %{
          node
          | latency_ms: latency,
            healthy: healthy,
            last_probe_at: DateTime.utc_now(),
            memory_pressure: memory_pressure
        }

      {:error, reason} ->
        Logger.warning("Ollama node #{name} at #{node.url} probe failed: #{inspect(reason)}")

        %{
          node
          | latency_ms: nil,
            healthy: false,
            last_probe_at: DateTime.utc_now()
        }
    end
  end

  defp send_probe(url, model) do
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => "1+1="}],
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers,
           recv_timeout: @probe_timeout_ms,
           timeout: @probe_timeout_ms
         ) do
      {:ok, %HTTPoison.Response{status_code: 200}} -> :ok
      {:ok, %HTTPoison.Response{status_code: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :probe_failed}
  end

  # Query Prometheus for node memory pressure (secondary signal, best-effort)
  defp check_memory_pressure(_node_name) do
    # node_exporter exposes node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
    # On macOS these may be named differently; treat as informational only
    query = "1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
    url = "#{@prometheus_url}/api/v1/query?query=#{URI.encode(query)}"

    case HTTPoison.get(url, [], recv_timeout: 3_000, timeout: 3_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => %{"result" => [%{"value" => [_, value]} | _]}}} ->
            {pressure, _} = Float.parse(value)
            pressure

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp local_model_for(:light), do: System.get_env("OLLAMA_MODEL_LIGHT", "ministral-3:3b")
  defp local_model_for(:medium), do: System.get_env("OLLAMA_MODEL_MEDIUM", "ministral-3:8b")
end
