defmodule BotArmyLlm.NodeQueue do
  @moduledoc """
  One generation at a time per Ollama node, and a bounded wait behind it.

  `OllamaHealthChecker` decides *which* node can take work. This decides *how
  much* work a node is already holding. They are different questions, and the
  second one is about hardware: a node has one GPU, so a second concurrent
  generation does not go faster — it makes both slower, and on a machine that is
  also somebody's laptop it makes the machine unusable.

  Measured 2026-10-01: a three-word uncensored job sat `pending` for over ten
  minutes while local nodes were loaded, cloud-routed work finished in three
  seconds, and nothing anywhere bounded how many jobs could land on one node.
  This is that bound.

  ## The rule

    * a node runs `OLLAMA_NODE_MAX_CONCURRENCY` jobs at once (default 1)
    * at most `OLLAMA_NODE_MAX_WAITING` more jobs wait behind them (default 2),
      first in first out
    * a job that waits longer than `OLLAMA_NODE_MAX_WAIT_MS` (default 600_000 —
      ten minutes, deliberately *inside* the 900 s a caller will poll before
      giving up) is told it timed out instead of waiting forever
    * a job arriving when the node is saturated and the wait list is full is
      refused with `{:error, :queue_full}`

  The refusal is the point. An unbounded queue is indistinguishable from a hang,
  which is the failure this module exists to remove.

  ## Waiting is per node, not global

  The key is the node's URL — the hardware — so air and mini each get their own
  slot and one node being busy never holds up the other.

  ## Failure modes open, not closed

  A concurrency guard that can wedge the bot would be worse than the pile-up it
  prevents, so: if this process is not running the work runs anyway, and if a
  holder dies without releasing its monitor frees the slot.
  """

  use GenServer
  require Logger

  @config_concurrency "OLLAMA_NODE_MAX_CONCURRENCY"
  @config_waiting "OLLAMA_NODE_MAX_WAITING"
  @config_wait_ms "OLLAMA_NODE_MAX_WAIT_MS"
  @default_concurrency 1
  @default_waiting 2
  @default_wait_ms 600_000
  @long_wait_log_ms 1_000

  @type key :: String.t()
  @type label :: String.t() | nil

  @doc """
  Starts the gate.

  `:max_concurrency`, `:max_waiting` and `:max_wait_ms` override the env limits;
  `:name` overrides the registered name (tests and, in principle, a second gate
  for a second fleet).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` while holding a slot on `key`, releasing it however `fun` ends.

  Returns `fun`'s own result, or the gate's refusal — `{:error, :queue_full}` or
  `{:error, :queue_timeout}` — which is shaped like a provider error so a caller
  (and the provider chain) can treat it as one.
  """
  @spec run(key(), label(), (-> result)) :: result | {:error, atom()}
        when result: term()
  def run(key, label, fun) when is_function(fun, 0) do
    case acquire_if_running(key, label) do
      :ok ->
        try do
          fun.()
        after
          release(key)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Takes a slot on `key`, or waits for one, or refuses.

  Always replies — `:ok`, `{:error, :queue_full}`, `{:error, :queue_timeout}` —
  so a caller may block on it forever without hanging on an answer that will
  never come.
  """
  @spec acquire(key(), label()) :: :ok | {:error, atom()}
  def acquire(key, label \\ nil) do
    GenServer.call(server(), {:acquire, key, label}, :infinity)
  end

  @doc "Gives back the slot taken by `acquire/2` on `key`."
  @spec release(key()) :: :ok
  def release(key) do
    GenServer.cast(server(), {:release, key, self()})
  end

  @doc "Which job holds each node, and which jobs wait behind it."
  @spec status() :: %{optional(key()) => map()}
  def status do
    GenServer.call(server(), :status)
  end

  @doc """
  The job id of the process doing the asking, when a chat job is the asker.

  Set by `BotArmyLlm.NATS.Consumer` on the process that runs the job, so a wait
  and a refusal can name the job they belong to instead of a bare pid — the
  difference between "mini is busy" and "job 4f2c… is why mini is busy".
  """
  @spec queued_label() :: label()
  def queued_label do
    Process.get(:llm_job_id)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       nodes: %{},
       max_concurrency:
         positive(opts[:max_concurrency], config(@config_concurrency, @default_concurrency)),
       max_waiting: non_negative(opts[:max_waiting], config(@config_waiting, @default_waiting)),
       max_wait_ms: positive(opts[:max_wait_ms], config(@config_wait_ms, @default_wait_ms))
     }}
  end

  @impl true
  def handle_call({:acquire, key, label}, from, state) do
    admit(key, from, label, state)
  end

  def handle_call(:status, _from, state) do
    {:reply, describe(state), state}
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    {:noreply, promote(key, drop_holder(state, key, pid))}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case owner_of(state, ref) do
      nil -> {:noreply, state}
      key -> {:noreply, promote(key, drop_ref(state, key, ref))}
    end
  end

  def handle_info({:wait_timeout, key, ref}, state) do
    {:noreply, expire(key, ref, state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The bot must keep serving if the guard is missing, so an absent queue means
  # "go ahead" rather than an exception on the generation path.
  defp acquire_if_running(key, label) do
    case Process.whereis(server()) do
      nil -> :ok
      _pid -> acquire(key, label)
    end
  end

  # The gate is a singleton in production and an injectable *name* in tests, the
  # same seam this bot uses for its health checker and rotator.
  defp server do
    Application.get_env(:bot_army_llm, :node_queue_server, __MODULE__)
  end

  defp admit(key, from, label, state) do
    node = node(state, key)
    {pid, _tag} = from

    cond do
      map_size(node.holders) < state.max_concurrency ->
        {:reply, :ok, put_node(state, key, add_holder(node, pid, label))}

      length(node.waiting) < state.max_waiting ->
        {:noreply, put_node(state, key, enqueue(node, key, from, label, state))}

      true ->
        log_refusal(key, label)
        {:reply, {:error, :queue_full}, state}
    end
  end

  defp enqueue(node, key, from, label, state) do
    {pid, _tag} = from
    ref = Process.monitor(pid)
    timer = Process.send_after(self(), {:wait_timeout, key, ref}, state.max_wait_ms)

    waiter = %{from: from, pid: pid, label: label, ref: ref, timer: timer, at: now_ms()}
    %{node | waiting: node.waiting ++ [waiter]}
  end

  defp expire(key, ref, state) do
    node = node(state, key)

    case Enum.split_with(node.waiting, &(&1.ref == ref)) do
      {[waiter], rest} ->
        GenServer.reply(waiter.from, {:error, :queue_timeout})
        Process.demonitor(waiter.ref, [:flush])

        Logger.warning(
          "LLM node #{key} refused #{label_of(waiter)} after waiting #{waited_ms(waiter)}ms " <>
            "(OLLAMA_NODE_MAX_WAIT_MS)"
        )

        put_node(state, key, %{node | waiting: rest})

      {[], _all} ->
        state
    end
  end

  defp promote(key, state) do
    node = node(state, key)

    if map_size(node.holders) < state.max_concurrency and node.waiting != [] do
      [waiter | rest] = node.waiting
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, :ok)
      log_long_wait(key, waiter)

      granted = %{node | waiting: rest}
      put_node(state, key, add_holder(granted, waiter.pid, waiter.label, waiter.ref))
    else
      state
    end
  end

  defp add_holder(node, pid, label, ref \\ nil) do
    ref = ref || Process.monitor(pid)

    %{
      node
      | holders: Map.put(node.holders, ref, %{pid: pid, label: label, at: now_ms(), ref: ref})
    }
  end

  defp drop_holder(state, key, pid) do
    node = node(state, key)

    {dropped, kept} =
      Enum.split_with(node.holders, fn {_ref, holder} -> holder.pid == pid end)

    Enum.each(dropped, fn {ref, _holder} -> Process.demonitor(ref, [:flush]) end)
    put_node(state, key, %{node | holders: Map.new(kept)})
  end

  defp drop_ref(state, key, ref) do
    node = node(state, key)

    case Map.pop(node.holders, ref) do
      {nil, _holders} ->
        put_node(state, key, %{node | waiting: Enum.reject(node.waiting, &(&1.ref == ref))})

      {_holder, holders} ->
        put_node(state, key, %{node | holders: holders})
    end
  end

  defp owner_of(state, ref) do
    Enum.find_value(state.nodes, fn {key, node} ->
      holding = Enum.any?(node.holders, fn {holder_ref, _} -> holder_ref == ref end)
      waiting = Enum.any?(node.waiting, &(&1.ref == ref))

      if holding or waiting, do: key
    end)
  end

  defp describe(state) do
    Map.new(state.nodes, fn {key, node} ->
      {key,
       %{
         running: node.holders |> Map.values() |> Enum.map(&label_of/1) |> Enum.sort(),
         waiting: Enum.map(node.waiting, &label_of/1),
         max_concurrency: state.max_concurrency,
         max_waiting: state.max_waiting
       }}
    end)
  end

  defp node(state, key) do
    Map.get_lazy(state.nodes, key, fn -> %{holders: %{}, waiting: []} end)
  end

  defp put_node(state, key, node) do
    %{state | nodes: Map.put(state.nodes, key, node)}
  end

  defp label_of(%{label: nil, pid: pid}), do: "pid:#{inspect(pid)}"
  defp label_of(%{label: label}), do: label

  defp log_long_wait(key, waiter) do
    waited = waited_ms(waiter)

    if waited >= @long_wait_log_ms do
      Logger.info(
        "LLM node #{key} was busy: job #{label_of(waiter)} waited #{waited}ms for its slot"
      )
    end
  end

  defp log_refusal(key, label) do
    Logger.warning(
      "LLM node #{key} is saturated and its wait list is full — refusing job " <>
        "#{label || "pid:#{inspect(self())}"} rather than queueing it without a bound"
    )
  end

  defp waited_ms(%{at: at}) when is_integer(at), do: now_ms() - at
  defp waited_ms(_waiter), do: 0

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp config(name, default) do
    name
    |> BotArmyLibraryRuntime.ConfigLoader.get(to_string(default))
    |> parse_int(default)
  rescue
    _error -> default
  end

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  rescue
    _error -> default
  end

  defp positive(value, default) do
    case value do
      nil -> default
      int when is_integer(int) and int > 0 -> int
      _other -> default
    end
  end

  defp non_negative(value, default) do
    case value do
      nil -> default
      int when is_integer(int) and int >= 0 -> int
      _other -> default
    end
  end
end
