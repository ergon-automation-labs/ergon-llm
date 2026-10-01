defmodule BotArmyLlm.NodeRotator do
  @moduledoc """
  Weighted round-robin across the local Ollama nodes.

  A caller does not have to know which machine can take its work: it sends
  `"ollama_node": "round-robin"` and this module names the node. Keeping the choice
  here means every bot shares one policy and one set of weights, instead of each
  caller inventing a preference that quietly drifts.

  Weights come from `OLLAMA_ROUND_ROBIN_WEIGHTS` — `"air:2,mini:1"` by default.
  The default is deliberately uneven: mini holds the 27B build and its warm-up is a
  17.7 GB load on an operator machine, so it takes the smaller share until someone
  says otherwise. A bare name (`"air"`) means weight 1; a weight below 1 drops the
  name. The schedule is read once at start-up, so changing the weights takes a bot
  restart.

  Only *eligible* names are considered — the caller passes the nodes its health view
  says are up. A scheduled name that is not eligible is skipped: routing to a node
  that is down is not a rotation, it is a failure with a nicer name. When none of
  the scheduled names is eligible the caller's own order decides, and when the
  caller has nothing this returns `nil` so the caller can decide what an empty
  rotation means (`BotArmyLlm.NATS.Consumer.rotation_node/1` hands the sentinel
  back, and the provider layer then refuses with an honest unknown-node error).
  """

  use GenServer

  @default_weights "air:2,mini:1"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The next eligible node name, or nil when `eligible` is empty."
  @spec next([atom() | String.t()]) :: String.t() | nil
  def next(eligible) when is_list(eligible) do
    case Process.whereis(__MODULE__) do
      nil -> List.first(normalize(eligible))
      _pid -> GenServer.call(__MODULE__, {:next, eligible})
    end
  end

  @doc "The configured weights as `{name, weight}` pairs."
  @spec weights() :: [{String.t(), pos_integer()}]
  def weights do
    case parse_weights(configured_weights()) do
      [] -> [{"air", 2}, {"mini", 1}]
      pairs -> pairs
    end
  end

  @doc "The expanded rotation order — one entry per unit of weight, then it repeats."
  @spec schedule() :: [String.t()]
  def schedule, do: expand(weights())

  @doc "Forget the rotation position. For tests; the counter is otherwise monotonic."
  @spec reset() :: :ok
  def reset do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :reset)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{counter: 0, schedule: schedule()}}

  @impl true
  def handle_call({:next, eligible}, _from, state) do
    names = normalize(eligible)

    case candidates(names, state.schedule) do
      [] ->
        {:reply, List.first(names), state}

      candidates ->
        name = Enum.at(candidates, rem(state.counter, length(candidates)))

        {:reply, name, %{state | counter: state.counter + 1}}
    end
  end

  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | counter: 0}}

  # Prefer the configured order, but never return a name the caller did not offer:
  # the caller's list is the health view, and this module has no way to know better.
  defp candidates(eligible, schedule) do
    case Enum.filter(schedule, &(&1 in eligible)) do
      [] -> eligible
      filtered -> filtered
    end
  end

  defp normalize(eligible) do
    eligible
    |> Enum.map(&normalize_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.trim()
  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(_other), do: ""

  defp expand(pairs),
    do: Enum.flat_map(pairs, fn {name, weight} -> List.duplicate(name, weight) end)

  defp configured_weights do
    BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_ROUND_ROBIN_WEIGHTS", @default_weights)
  end

  # Unparseable input yields [] and the caller falls back to the default rather than
  # rotating over an empty schedule. A typo in an env var must not silently stop
  # naming nodes.
  defp parse_weights(raw) do
    raw
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_weight/1)
  end

  defp parse_weight(entry) do
    case String.split(entry, ":", parts: 2) do
      [name] -> with_weight(name, 1)
      [name, weight] -> with_weight(name, parse_int(weight))
    end
  end

  defp with_weight(name, weight) do
    name = String.trim(name)
    if name == "" or weight < 1, do: [], else: [{name, weight}]
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> 0
    end
  end
end
