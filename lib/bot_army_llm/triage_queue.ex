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

  alias BotArmyLlm.{CircuitBreaker, Triage}

  @all_cloud_providers [:blackbox, :openrouter, :anthropic]

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

  @doc """
  First caller to claim a request id wins: `:dispatch` (the answer goes straight to
  the caller) or `:ack` (the caller already got a queued reply, so the answer goes to
  the job store). Returns `true` for the winner, `false` for everyone after.

  A claim is held for an hour and then pruned, rather than released when the answer
  goes out: releasing it would let a late ack re-answer a caller who already has the
  result.
  """
  def claim(server \\ __MODULE__, id, who) when who in [:dispatch, :ack],
    do: GenServer.call(server, {:claim, id, who})

  @claim_ttl_s 3_600

  @doc "Depth by lane, mode, oldest wait, waiting-for-cloud count, in-flight, shed and dispatch totals, last tick."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :cloud_providers, configured_cloud_providers())
    breaker = Keyword.get(opts, :breaker_state, &breaker_state/1)

    state = %{
      items: [],
      mode: Keyword.get(opts, :mode, :cloud),
      auto_mode: Keyword.get(opts, :auto_mode, false),
      cloud_providers: providers,
      cloud_probe: Keyword.get(opts, :cloud_probe, fn -> Enum.map(providers, breaker) end),
      breaker_state: breaker,
      probe: Keyword.get(opts, :probe, &BotArmyLlm.LlmClient.probe_provider/1),
      to_triage_after: Keyword.get(opts, :to_triage_after, 2),
      to_cloud_after: Keyword.get(opts, :to_cloud_after, 2),
      flip_run: 0,
      claims: %{},
      slots: Keyword.get(opts, :slots, @default_slots),
      in_flight: 0,
      dispatch: Keyword.get(opts, :dispatch, fn item -> item.work.() end),
      clock: Keyword.get(opts, :clock, &System.system_time/1),
      shed_bound: Keyword.get(opts, :shed_bound, 50),
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      last_tick_at: nil,
      shed_total: 0,
      expired_total: 0,
      kick: Keyword.get(opts, :kick, false),
      dispatched_total: 0
    }

    # Start in the mode the breakers call for, not in the configured default. A restart with every
    # cloud breaker open must start in triage; it used to start in cloud and wait two ticks to find out.
    state =
      if state.auto_mode,
        do: %{state | mode: Triage.cloud_mode(state.cloud_probe.())},
        else: state

    Logger.info(
      "[TriageQueue] started: mode=#{state.mode} auto_mode=#{state.auto_mode} slots=#{state.slots}"
    )

    schedule(state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, item}, _from, state) do
    item = Map.put_new_lazy(item, :enqueued_at, fn -> state.clock.(:second) end)
    item = with_expiry(item)
    state = %{state | items: state.items ++ [item]}

    # With `kick` on, an item that finds a free slot runs at once instead of waiting for the next
    # tick, which would add up to a whole tick to every request. An item that finds none waits and
    # is ranked as before. Off by default so a test (or an operator) can watch the line form.
    state = if state.kick, do: dispatch_free(state), else: state
    {:reply, :ok, state}
  end

  def handle_call({:set_mode, mode}, _from, state) do
    Logger.info("[TriageQueue] mode -> #{mode}")
    {:reply, :ok, %{state | mode: mode}}
  end

  def handle_call(:tick, _from, state) do
    state = evaluate(state)
    {:reply, summary(state), state}
  end

  def handle_call({:claim, id, who}, _from, state) do
    if Map.has_key?(state.claims, id) do
      {:reply, false, state}
    else
      at = state.clock.(:second)
      {:reply, true, %{state | claims: Map.put(state.claims, id, {who, at})}}
    end
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

  # The cloud breakers' view of the world, read once per tick.
  # The cloud providers the configured chain can use, in chain order. A provider removed from the
  # chain drops out here, so the queue never waits on a breaker nothing can call.
  defp configured_cloud_providers do
    BotArmyLlm.LlmClient.resolved_provider_chain()
    |> Enum.filter(&(&1 in @all_cloud_providers))
  end

  defp breaker_state(provider), do: CircuitBreaker.get_state(provider).state

  # In triage, the queue probes its own open cloud breakers. Ordinary traffic runs on Ollama
  # first and may never reach a cloud provider, so nothing else would move an open breaker to
  # half-open and let it recover. Each probe runs in its own task: the tick never waits on it,
  # and a breaker that is already half-open is not probed twice.
  defp probe_open_clouds(%{mode: :triage} = state) do
    for provider <- state.cloud_providers, state.breaker_state.(provider) == :open do
      Logger.info("[TriageQueue] probing open cloud breaker #{provider}")
      Task.start(fn -> state.probe.(provider) end)
    end

    state
  end

  defp probe_open_clouds(state), do: state

  # Automatic mode with hysteresis: the desired mode must hold for N consecutive
  # ticks before the queue flips, so a flapping provider cannot toggle it.
  defp auto_mode(%{auto_mode: false} = state), do: state

  defp auto_mode(state) do
    desired = Triage.cloud_mode(state.cloud_probe.())

    cond do
      desired == state.mode ->
        %{state | flip_run: 0}

      true ->
        run = state.flip_run + 1
        needed = if desired == :triage, do: state.to_triage_after, else: state.to_cloud_after

        if run >= needed do
          Logger.info("[TriageQueue] automatic mode #{state.mode} -> #{desired}")
          %{state | mode: desired, flip_run: 0}
        else
          %{state | flip_run: run}
        end
    end
  end

  defp evaluate(state) do
    state = auto_mode(state)
    state = probe_open_clouds(state)
    now = state.clock.(:second)
    state = %{state | claims: prune_claims(state.claims, now)}
    state = expire_items(state, now)

    {kept, shed} = Triage.shed(state.items, now, shed_bound: state.shed_bound)

    Enum.each(shed, fn {item, reason} ->
      Logger.warning("[TriageQueue] shed #{item.id} (#{item.lane}): #{reason}")
    end)

    state = %{state | items: kept, shed_total: state.shed_total + length(shed)}
    state = dispatch_free(state)
    %{state | last_tick_at: now}
  end

  # `expire_after_s` is relative to the queue's own clock, so there is one clock in the system.
  defp with_expiry(%{expire_after_s: s} = item) when is_integer(s) and s > 0 do
    Map.put_new(item, :expires_at, item.enqueued_at + s)
  end

  defp with_expiry(item), do: item

  # An item may carry `expires_at` (when its caller will have stopped listening) and `on_expire`
  # (how to tell them). Waiting past it, it is removed and told so rather than run for nobody: on
  # a loaded host a slot spent on an answer no one reads is a slot a live request did not get.
  defp expire_items(state, now) do
    {expired, live} =
      Enum.split_with(state.items, fn
        %{expires_at: at} when is_integer(at) -> now >= at
        _ -> false
      end)

    Enum.each(expired, fn item ->
      Logger.warning("[TriageQueue] expired #{item.id} (#{item.lane}) still waiting")

      case Map.get(item, :on_expire) do
        fun when is_function(fun, 0) ->
          Task.start(fn ->
            try do
              fun.()
            rescue
              error ->
                Logger.error(
                  "[TriageQueue] on_expire for #{item.id} failed: #{Exception.message(error)}"
                )
            end
          end)

        _ ->
          :ok
      end
    end)

    %{state | items: live, expired_total: state.expired_total + length(expired)}
  end

  # Runs the best-ranked items that fit in the free slots; the rest keep waiting.
  defp dispatch_free(state) do
    now = state.clock.(:second)
    free = max(state.slots - state.in_flight, 0)
    me = self()

    {to_run, rest} =
      state.items
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
        dispatched_total: state.dispatched_total + length(to_run)
    }
  end

  defp prune_claims(claims, now) do
    Map.filter(claims, fn {_id, {_who, at}} -> now - at < @claim_ttl_s end)
  end

  defp summary(state) do
    now = state.clock.(:second)

    by_lane =
      Enum.reduce(state.items, %{"urgent" => 0, "interactive" => 0, "background" => 0}, fn item,
                                                                                           acc ->
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
      expired_total: state.expired_total,
      dispatched_total: state.dispatched_total,
      last_tick_at: state.last_tick_at,
      cloud_breakers:
        Map.new(state.cloud_providers, fn provider ->
          {to_string(provider), to_string(state.breaker_state.(provider))}
        end)
    }
  end
end
