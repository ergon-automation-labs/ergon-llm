defmodule BotArmyLlm.LocalOllama do
  @moduledoc """
  The `local_ollama` source: local Ollama models the caller names, on a breaker of
  their own, with a deadline and a line long enough for a batch of async jobs.

  It is a provider like `ollama`, `blackbox` and `anthropic`, but it is selected by
  the caller (`"source": "local_ollama"`), never by the default chain, and it never
  falls back to another provider. Its failures and 429s cannot open the default
  `ollama` breaker, and the default chain's cannot open this one.

  ## Models are the pillar's to name

  No model is named in code. `LOCAL_OLLAMA_MODELS` (rendered by salt from
  `llm:local_ollama:models`) is a JSON list of `{"model": "...", "node": "mini"}`;
  the first entry is the default model and a `null`/absent node means the best
  local node. An entry may instead list `"nodes": ["mini", "air"]`: the work is spread across the
  healthy ones (see `order_nodes/1`) and each node must hold the model. With no list the source fails closed (`:model_not_configured`)
  rather than substituting a model. Numeric limits are config too:
  `LOCAL_OLLAMA_TIMEOUT_MS`, `LOCAL_OLLAMA_MAX_TIMEOUT_MS`, `LOCAL_OLLAMA_MAX_WAITING`.
  """

  @default_timeout_ms 180_000
  @max_timeout_ms 600_000
  @default_waiting 64

  @doc "The configured `%{\"model\", \"node\"}` entries, default first; `[]` when unset or unreadable."
  @spec models() :: [map()]
  def models do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get("LOCAL_OLLAMA_MODELS"),
         {:ok, [_ | _] = list} <- Jason.decode(raw),
         true <- Enum.all?(list, &(is_map(&1) and is_binary(&1["model"]) and &1["model"] != "")) do
      Enum.map(list, fn entry ->
        %{
          "model" => entry["model"],
          "node" => blank_to_nil(entry["node"]),
          "nodes" => nodes_of(entry["nodes"])
        }
      end)
    else
      _ -> []
    end
  end

  @doc """
  Resolve a request's opts to the model, node and deadline it will run with.

  An absent or `"auto"` model is the first configured one. A model that is not
  configured is refused by name, so the caller sees what is allowed instead of a
  silent swap; with nothing configured the source is refused outright.
  """
  @spec resolve(keyword()) ::
          {:ok,
           %{
             model: String.t(),
             node: String.t() | nil,
             nodes: [String.t()],
             timeout_ms: pos_integer()
           }}
          | {:error, {:model_not_allowed, String.t(), [String.t()]}}
          | {:error, {:model_not_configured, :local_ollama}}
  def resolve(opts) do
    case models() do
      [] -> {:error, {:model_not_configured, :local_ollama}}
      allowed -> resolve_in(allowed, opts)
    end
  end

  defp resolve_in(allowed, opts) do
    requested =
      case Keyword.get(opts, :model) do
        value when is_binary(value) and value not in ["", "auto"] -> value
        _ -> hd(allowed)["model"]
      end

    case Enum.find(allowed, &(&1["model"] == requested)) do
      nil ->
        {:error, {:model_not_allowed, requested, Enum.map(allowed, & &1["model"])}}

      entry ->
        # An entry that offers several nodes pins none: which one answers is decided per request.
        {node, nodes} =
          case entry["nodes"] do
            [_ | _] = nodes -> {nil, nodes}
            _ -> {entry["node"], []}
          end

        {:ok, %{model: entry["model"], node: node, nodes: nodes, timeout_ms: timeout_ms(opts)}}
    end
  end

  defp nodes_of(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp nodes_of(_other), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp blank_to_nil(_value), do: nil

  @doc """
  The nodes of a multi-node model, in the order to try them.

  The weighted rotator (`BotArmyLlm.NodeRotator`, weights from `OLLAMA_ROUND_ROBIN_WEIGHTS`) is
  offered only the healthy nodes among them, and its pick goes first. The rest follow in the order
  configured, an unhealthy one last: the health reading is a latency probe and can be wrong about a
  node that would answer, so a node is never dropped, only tried later. With none healthy, or the
  health view unreadable, the configured order stands: an unreadable value is absent, not a guess.
  """
  @spec order_nodes([String.t()]) :: [String.t()]
  def order_nodes([]), do: []
  def order_nodes([_only] = nodes), do: nodes

  def order_nodes(nodes) do
    case healthy_among(nodes) do
      [] ->
        nodes

      eligible ->
        case rotator().next(eligible) do
          pick when is_binary(pick) and pick != "" ->
            if pick in nodes, do: [pick | List.delete(nodes, pick)], else: nodes

          _ ->
            nodes
        end
    end
  end

  @doc """
  The first node that `accept` takes: `accept.(node)` answers `{:ok, found}` or `{:error, reason}`.
  Every node refusing is the last refusal, by name.
  """
  @spec first_usable([String.t()], (String.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def first_usable(nodes, accept) do
    Enum.reduce_while(nodes, {:error, :no_nodes}, fn node, _last ->
      case accept.(node) do
        {:ok, _found} = ok -> {:halt, ok}
        {:error, _reason} = refused -> {:cont, refused}
      end
    end)
  end

  defp healthy_among(nodes) do
    healthy =
      health_checker().node_status()
      |> Enum.filter(& &1.healthy)
      |> MapSet.new(&to_string(&1.name))

    Enum.filter(nodes, &MapSet.member?(healthy, &1))
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp health_checker,
    do: Application.get_env(:bot_army_llm, :ollama_health_checker, BotArmyLlm.OllamaHealthChecker)

  defp rotator, do: Application.get_env(:bot_army_llm, :node_rotator, BotArmyLlm.NodeRotator)

  @doc "The caller's `timeout_ms`, clamped to the configured ceiling; the configured default when absent."
  @spec timeout_ms(keyword()) :: pos_integer()
  def timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms) do
      value when is_integer(value) and value > 0 ->
        min(value, number("LOCAL_OLLAMA_MAX_TIMEOUT_MS", @max_timeout_ms))

      _ ->
        number("LOCAL_OLLAMA_TIMEOUT_MS", @default_timeout_ms)
    end
  end

  @doc "How many jobs may wait behind a running one on a node (a batch is polled, not dropped)."
  @spec max_waiting() :: pos_integer()
  def max_waiting, do: number("LOCAL_OLLAMA_MAX_WAITING", @default_waiting)

  defp number(key, default) do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get(key),
         {value, ""} when value > 0 <- Integer.parse(raw) do
      value
    else
      _ -> default
    end
  end
end
