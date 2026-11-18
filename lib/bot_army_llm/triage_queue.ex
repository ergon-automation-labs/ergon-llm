defmodule BotArmyLlm.TriageQueue do
  @moduledoc """
  Holds LLM requests waiting for a model and dispatches them in priority order.

  Each tick (and each `enqueue/1`) the queue:

    1. sheds background items beyond its bound (visibly, with a reason),
    2. ranks what is left with `BotArmyLlm.Triage`,
    3. dispatches the top items that the current mode allows, up to the free slots.

  The queue records `last_tick_at` on every tick. That is its progress time: a queue
  whose tick is old is stuck, and the stuck check reads it the same way it reads any
  other progress field.

  Dispatch and clock are injected, so this runs without NATS or a model. The process
  is not started by the application yet; it is opt-in until it is wired and proven.
  """

  use GenServer
  require Logger

  alias BotArmyLlm.Triage

  @default_slots 2
  @default_tick_ms 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a request. The item needs `id`, `lane`, and optionally `enqueued_at` (unix seconds)."
  def enqueue(server \\ __MODULE__, item), do: GenServer.call(server, {:enqueue, item})

  @doc "`:cloud` or `:triage`."
  def set_mode(server \\ __MODULE__, mode) when mode in [:cloud, :triage],
    do: GenServer.call(server, {:set_mode, mode})

  @doc "Run one evaluator pass now. Returns the status after the pass."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Depth by lane, mode, oldest wait, waiting-for-cloud count, in-flight, shed and dispatch totals, last tick."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %{
      items: [],
      mode: :cloud,
      slots: Keyword.get(opts, :slots, @default_slots),
      in_flight: 0,
      dispatch: Keyword.get(opts, :dispatch, fn _item -> :ok end),
      clock: Keyword.get(opts, :clock, &System.system_time/1),
      shed_bound: Keyword.get(opts, :shed_bound, 50),
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      last_tick_at: nil,
      shed_total: 0,
      dispatched_total: 0
    }

    schedule(state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, item}, _from, state) do
    item = Map.put_new_lazy(item, :enqueued_at, fn -> state.clock.(:second) end)
    {:reply, :ok, %{state | items: state.items ++ [item]}}
  end

  def handle_call({:set_mode, mode}, _from, state) do
    Logger.info("[TriageQueue] mode -> #{mode}")
    {:reply, :ok, %{state | mode: mode}}
  end

  def handle_call(:tick, _from, state) do
    state = evaluate(state)
    {:reply, summary(state), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, summary(state), state}
  end

  @impl true
  def handle_cast({:done, _id}, state) do
    {:noreply, %{state | in_flight: max(state.in_flight - 1, 0)}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = evaluate(state)
    schedule(state.tick_ms)
    {:noreply, state}
  end

  defp schedule(ms) when is_integer(ms) and ms > 0, do: Process.send_after(self(), :tick, ms)
  defp schedule(_), do: :ok

  defp evaluate(state) do
    now = state.clock.(:second)

    {kept, shed} = Triage.shed(state.items, now, shed_bound: state.shed_bound)
    Enum.each(shed, fn {item, reason} ->
      Logger.warning("[TriageQueue] shed #{item.id} (#{item.lane}): #{reason}")
    end)

    free = max(state.slots - state.in_flight, 0)
    me = self()

    {to_run, rest} =
      kept
      |> Triage.rank(now)
      |> Enum.reduce({[], []}, fn {item, _score, _reasons}, {run, wait} ->
        route = Triage.route(item, state.mode)

        if route != :waiting_for_cloud and length(run) < free do
          {[item | run], wait}
        else
          {run, [item | wait]}
        end
      end)

    Enum.each(to_run, fn item ->
      Task.start(fn ->
        try do
          state.dispatch.(item)
        after
          GenServer.cast(me, {:done, item.id})
        end
      end)
    end)

    %{
      state
      | items: Enum.reverse(rest),
        in_flight: state.in_flight + length(to_run),
        shed_total: state.shed_total + length(shed),
        dispatched_total: state.dispatched_total + length(to_run),
        last_tick_at: now
    }
  end

  defp summary(state) do
    now = state.clock.(:second)

    by_lane =
      Enum.reduce(state.items, %{"urgent" => 0, "interactive" => 0, "background" => 0}, fn item, acc ->
        Map.update(acc, item.lane, 1, &(&1 + 1))
      end)

    oldest =
      case state.items do
        [] -> 0
        items -> now - Enum.min(Enum.map(items, & &1.enqueued_at))
      end

    waiting_for_cloud =
      Enum.count(state.items, &(Triage.route(&1, state.mode) == :waiting_for_cloud))

    %{
      mode: state.mode,
      depth: length(state.items),
      by_lane: by_lane,
      oldest_wait_s: oldest,
      waiting_for_cloud: waiting_for_cloud,
      in_flight: state.in_flight,
      slots: state.slots,
      shed_total: state.shed_total,
      dispatched_total: state.dispatched_total,
      last_tick_at: state.last_tick_at
    }
  end
end
