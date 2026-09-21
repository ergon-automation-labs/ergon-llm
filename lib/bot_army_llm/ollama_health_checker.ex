defmodule BotArmyLlm.OllamaHealthChecker do
  @moduledoc """
  Background GenServer that probes configured Ollama nodes every 60 seconds.

  Uses a cheap probe request ("1+1=") with gemma3:1b to measure response latency.
  Nodes exceeding the degraded latency threshold are marked unhealthy.
  Prometheus memory pressure is checked as a secondary signal.

  ## Routing
  - best_ollama_node/1 returns the lowest-latency healthy node for the given
    complexity, considering only nodes that are not `explicit_only`
  - best_ollama_node/2 targets one named node, ignoring latency and
    `explicit_only`. Returns {:error, {:unknown_node | :node_not_configured |
    :node_disabled | :node_unhealthy, name}} when it cannot serve

  ## Explicit-only nodes
  Mini holds models air does not (baytout3/qwen3.5-uncensored:27B). It is
  `explicit_only` by default: latency selection must never route general traffic
  to a node whose warm-up is a 17.7 GB load on the operator's machine. Callers
  ask for it by name:

      call_provider(:ollama, text, complexity,
        model: "baytout3/qwen3.5-uncensored:27B", ollama_node: "mini")

  Set OLLAMA_MINI_EXPLICIT_ONLY=false to fold mini back into latency selection.

  ## Env vars
    OLLAMA_URL              - Air node Ollama URL (fallback: OLLAMA_BASE_URL; default: http://localhost:11434)
    OLLAMA_MINI_URL         - Mini node Ollama URL (empty = not configured)
    OLLAMA_MINI_EXPLICIT_ONLY - Mini is only used when named (default: true)
    OLLAMA_MINI_MODEL       - Default model for the mini node (empty = complexity tiers)
    OLLAMA_PROBE_MODEL      - Model for health probes (default: gemma3:1b)
    OLLAMA_MINI_PROBE_MODEL - Probe model for the mini node (default: OLLAMA_PROBE_MODEL)
    OLLAMA_MODEL_LIGHT      - Model for light tasks (default: ministral-3:3b)
    OLLAMA_MODEL_MEDIUM     - Model for medium tasks (default: ministral-3:8b)
    OLLAMA_DEGRADED_LATENCY_MS - Latency threshold for healthy status (default: 8000)
  """

  use GenServer
  require Logger

  @probe_interval_ms 60_000
  @probe_timeout_ms 120_000
  @prometheus_url "http://localhost:30090"

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the best Ollama URL + model for a given complexity level, using only
  nodes eligible for implicit latency-based routing.
  Returns {:ok, {url, model}} | {:error, :no_healthy_nodes}
  """
  @spec best_ollama_node(:light | :medium | :heavy) ::
          {:ok, {String.t(), String.t()}} | {:error, atom()}
  def best_ollama_node(complexity), do: best_ollama_node(complexity, nil)

  @doc """
  Returns the URL + model for one named node ("air", "mini", ...), bypassing
  latency ordering and the explicit-only filter. nil / "" / "auto" behave like
  best_ollama_node/1.
  """
  @spec best_ollama_node(:light | :medium | :heavy, atom() | String.t() | nil) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def best_ollama_node(complexity, node_name) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :health_checker_not_running}
      _pid -> GenServer.call(__MODULE__, {:best_node, complexity, node_name})
    end
  end

  @doc "Returns current health status of all configured nodes."
  def node_status do
    GenServer.call(__MODULE__, :node_status)
  end

  @doc """
  Returns true if all enabled nodes have acceptable CPU and memory load.
  When metrics are unavailable (Prometheus unreachable), treats as acceptable (fail-open).
  """
  @spec load_acceptable?() :: boolean()
  def load_acceptable? do
    GenServer.call(__MODULE__, :load_acceptable?)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = build_initial_state()
    # Run initial probe synchronously to avoid race where LLM client queries before first probe
    initial_state = probe_all_nodes(state)
    # Schedule subsequent probes asynchronously
    Process.send_after(self(), :probe, @probe_interval_ms)
    {:ok, initial_state}
  end

  @impl true
  def handle_info(:probe, state) do
    new_state = probe_all_nodes(state)
    Process.send_after(self(), :probe, @probe_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:best_node, complexity}, from, state),
    do: handle_call({:best_node, complexity, nil}, from, state)

  @impl true
  def handle_call({:best_node, complexity, node_name}, _from, state) do
    result =
      case normalize_node_name(node_name) do
        :implicit ->
          state.nodes
          |> Enum.filter(fn {_name, node} -> implicit_candidate?(node) end)
          |> Enum.sort_by(fn {_name, node} -> latency_rank(node) end)
          |> case do
            [{_name, node} | _] -> {:ok, {node.url, node_model(node, complexity)}}
            [] -> {:error, :no_healthy_nodes}
          end

        name ->
          explicit_node_result(state.nodes, name, complexity)
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
          memory_pressure: node.memory_pressure,
          explicit_only: Map.get(node, :explicit_only, false),
          default_model: Map.get(node, :default_model)
        }
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_call(:load_acceptable?, _from, state) do
    mem_threshold =
      BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_HIGH_MEMORY_THRESHOLD", "0.80")
      |> String.to_float()

    cpu_threshold =
      BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_HIGH_CPU_THRESHOLD", "0.80")
      |> String.to_float()

    acceptable =
      state.nodes
      |> Enum.filter(fn {_name, node} -> node.enabled end)
      |> Enum.all?(fn {_name, node} ->
        mem_ok = node.memory_pressure == nil or node.memory_pressure < mem_threshold
        cpu_ok = node.cpu_load == nil or node.cpu_load < cpu_threshold
        mem_ok and cpu_ok
      end)

    {:reply, acceptable, state}
  end

  # Private

  defp build_initial_state do
    %{
      nodes: %{
        air: %{
          # P10 (2026-09-06, Docker fleet test): the starter ships the generic
          # OLLAMA_BASE_URL (http://ollama:11434) while this bot historically
          # reads OLLAMA_URL — the mismatch left all LLM routing pointed at
          # localhost:11434 (refused). Accept either dialect.
          url:
            BotArmyLibraryRuntime.ConfigLoader.get(
              "OLLAMA_URL",
              BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
            ),
          latency_ms: nil,
          last_probe_at: nil,
          healthy: false,
          memory_pressure: nil,
          cpu_load: nil,
          enabled: true,
          # Air is the default host — implicit latency routing may use it.
          explicit_only: false,
          default_model: nil,
          probe_model: nil
        },
        mini: %{
          url: BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MINI_URL", ""),
          latency_ms: nil,
          last_probe_at: nil,
          healthy: false,
          memory_pressure: nil,
          cpu_load: nil,
          enabled: true,
          # Mini is only reachable on purpose: general traffic must not be
          # pulled onto the 27B model by a latency win.
          explicit_only:
            BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MINI_EXPLICIT_ONLY", "true")
            |> parse_bool(true),
          default_model: nilify(BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MINI_MODEL", "")),
          probe_model:
            nilify(BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MINI_PROBE_MODEL", ""))
        }
      },
      probe_model: BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_PROBE_MODEL", "gemma3:1b"),
      degraded_latency_ms:
        BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_DEGRADED_LATENCY_MS", "8000")
        |> String.to_integer()
    }
  end

  defp probe_all_nodes(state) do
    nodes =
      Map.new(state.nodes, fn {name, node} ->
        # A node that does not carry the cluster's probe model (mini has no
        # gemma3:1b) would otherwise pull it on first probe.
        probe_model = Map.get(node, :probe_model) || state.probe_model
        updated = probe_node(name, node, probe_model, state.degraded_latency_ms)
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
        cpu_load = check_cpu_load(node.url)
        healthy = latency < degraded_latency_ms

        unless healthy do
          Logger.warning(
            "Ollama node #{name} probe latency #{latency}ms exceeds #{degraded_latency_ms}ms threshold"
          )
        end

        Logger.debug(
          "Ollama node #{name} probe ok: #{latency}ms, memory=#{inspect(memory_pressure)}, cpu_load=#{inspect(cpu_load)}"
        )

        %{
          node
          | latency_ms: latency,
            healthy: healthy,
            last_probe_at: DateTime.utc_now(),
            memory_pressure: memory_pressure,
            cpu_load: cpu_load
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

  # Query Prometheus for node CPU load (normalized by logical processors)
  defp check_cpu_load(_node_url) do
    prometheus_url = System.get_env("PROMETHEUS_URL", @prometheus_url)
    url = "#{prometheus_url}/api/v1/query?query=#{URI.encode("node_load1")}"
    cpu_count = max(:erlang.system_info(:logical_processors), 1)

    case HTTPoison.get(url, [], recv_timeout: 2_000, connect_timeout: 1_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => %{"result" => [%{"value" => [_, val]} | _]}}} ->
            {load, _} = Float.parse(val)
            load / cpu_count

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp local_model_for(:light),
    do: BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MODEL_LIGHT", "ministral-3:3b")

  defp local_model_for(:medium),
    do: BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MODEL_MEDIUM", "ministral-3:8b")

  defp local_model_for(:heavy),
    do: BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_MODEL_HEAVY", "ministral-3:8b")

  # Routing helpers

  defp normalize_node_name(nil), do: :implicit
  defp normalize_node_name(name) when is_atom(name), do: Atom.to_string(name)

  defp normalize_node_name(name) when is_binary(name) do
    case name |> String.trim() |> String.downcase() do
      "" -> :implicit
      "auto" -> :implicit
      other -> other
    end
  end

  defp normalize_node_name(_other), do: :implicit

  defp implicit_candidate?(node) do
    Map.get(node, :enabled, true) and not Map.get(node, :explicit_only, false) and
      node_healthy?(node)
  end

  defp node_healthy?(node), do: node.healthy == true and node.url not in [nil, ""]

  defp latency_rank(node) do
    penalty = if (node.memory_pressure || 0) > 0.7, do: 5_000, else: 0
    (node.latency_ms || 0) + penalty
  end

  defp explicit_node_result(nodes, wanted, complexity) do
    case find_node(nodes, wanted) do
      :error ->
        {:error, {:unknown_node, wanted}}

      {:ok, node} ->
        cond do
          node.url in [nil, ""] -> {:error, {:node_not_configured, wanted}}
          Map.get(node, :enabled, true) == false -> {:error, {:node_disabled, wanted}}
          not node_healthy?(node) -> {:error, {:node_unhealthy, wanted}}
          true -> {:ok, {node.url, node_model(node, complexity)}}
        end
    end
  end

  defp find_node(nodes, wanted) do
    Enum.find_value(nodes, :error, fn {name, node} ->
      if Atom.to_string(name) == wanted, do: {:ok, node}
    end)
  end

  # An explicitly named node may carry its own model — a 27B is not a tier.
  defp node_model(node, complexity) do
    case Map.get(node, :default_model) do
      model when is_binary(model) and model != "" -> model
      _ -> local_model_for(complexity)
    end
  end

  defp parse_bool(value, _default) when is_boolean(value), do: value

  defp parse_bool(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> true
      "1" -> true
      "yes" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      _ -> default
    end
  end

  defp parse_bool(_value, default), do: default

  defp nilify(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp nilify(_value), do: nil
end
