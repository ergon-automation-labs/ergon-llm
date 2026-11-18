defmodule BotArmyLlm.Triage do
  @moduledoc """
  Priority ranking for LLM requests waiting for a model, used when cloud is out.

  Pure functions: no NATS, no process state. The queue owner calls `rank/2` on each
  tick and on each arrival, and `route/2` to decide where a ranked item may run.

  ## Score

      score = lane_weight + aging + sender_bonus - size_penalty

    * lane: `urgent` 300, `interactive` 200, `background` 100. Lane dominates.
    * aging: +1 point per `aging_seconds` (default 30s) of waiting, capped at
      `aging_cap` (default 99). The cap sits below the 100-point lane gap, so aging
      only reorders items inside a lane and never lifts anything across a lane.
    * promotion (starvation guard): a background item that has waited
      `promote_after_seconds` (default 7200, two hours) is treated as interactive.
      Urgent is never granted by promotion; it is only ever set by the caller.
    * sender_bonus: `:user` (your own chat) +20, `:system` 0, `:automated` -10.
    * size_penalty: estimated tokens / 1000, capped at 50, so small requests go first
      inside a lane.

  Every ranking returns its reasons, so the choice can be read back later.

  ## Modes

    * `:cloud` — no restriction; everything may run anywhere.
    * `:triage` — cloud is out. Items run on local models only; cloud-only items wait
      with reason `:waiting_for_cloud`.
  """

  @lane_weights %{"urgent" => 300, "interactive" => 200, "background" => 100}
  @sender_bonus %{user: 20, system: 0, automated: -10}
  @defaults %{aging_seconds: 30, aging_cap: 99, promote_after_seconds: 7200, shed_bound: 50}

  @type item :: %{
          required(:id) => String.t(),
          required(:lane) => String.t(),
          required(:enqueued_at) => integer(),
          optional(:sender) => :user | :system | :automated,
          optional(:est_tokens) => non_neg_integer(),
          optional(:local_only) => boolean(),
          optional(:cloud_only) => boolean()
        }

  @doc "Score one item at `now` (unix seconds). Returns `{score, reasons}`."
  @spec score(item(), integer(), keyword()) :: {integer(), [atom()]}
  def score(item, now, opts \\ []) do
    cfg = config(opts)
    waited = max(now - item.enqueued_at, 0)
    lane = effective_lane(item, waited, cfg)

    aging = min(div(waited, cfg.aging_seconds), cfg.aging_cap)
    sender = Map.get(@sender_bonus, Map.get(item, :sender, :system), 0)
    size = min(div(Map.get(item, :est_tokens, 0), 1000), 50)

    reasons =
      [
        {:lane, lane},
        {:waited_s, waited},
        {:aging, aging},
        {:sender, sender},
        {:size_penalty, size}
      ] ++ if(lane != item.lane, do: [{:promoted_from, item.lane}], else: [])

    {Map.fetch!(@lane_weights, lane) + aging + sender - size, reasons}
  end

  @doc """
  Rank items, highest score first. Ties break on earlier arrival, then id, so the
  order is deterministic. Returns `[{item, score, reasons}]`.
  """
  @spec rank([item()], integer(), keyword()) :: [{item(), integer(), [atom()]}]
  def rank(items, now, opts \\ []) do
    items
    |> Enum.map(fn item ->
      {score, reasons} = score(item, now, opts)
      {item, score, reasons}
    end)
    |> Enum.sort_by(fn {item, score, _} -> {-score, item.enqueued_at, item.id} end)
  end

  @doc """
  The mode the cloud breakers call for. `:triage` when no cloud provider is closed
  (all open or probing), `:cloud` as soon as any one closes. No providers reported
  means no evidence cloud is out, so `:cloud`.
  """
  @spec cloud_mode([atom()]) :: :cloud | :triage
  def cloud_mode([]), do: :cloud
  def cloud_mode(states), do: if(Enum.any?(states, &(&1 == :closed)), do: :cloud, else: :triage)

  @doc """
  Where an item may run in a mode: `:local`, `:cloud`, or `:waiting_for_cloud`.

    * `local_only` (for example `model_type: "uncensored"`) always runs local.
    * `cloud_only` (the request needs a cloud model) waits in triage mode.
    * everything else runs local in triage mode and anywhere in cloud mode.
  """
  @spec route(item(), :cloud | :triage) :: :local | :cloud | :waiting_for_cloud
  def route(item, :cloud), do: if(Map.get(item, :local_only, false), do: :local, else: :cloud)

  def route(item, :triage) do
    cond do
      Map.get(item, :local_only, false) -> :local
      Map.get(item, :cloud_only, false) -> :waiting_for_cloud
      true -> :local
    end
  end

  @doc """
  Shed the lowest-ranked background items beyond `shed_bound`. Only background
  items are ever shed; urgent and interactive work is never dropped. Returns
  `{kept, shed}`, where each shed entry carries the reason, so nothing vanishes
  silently.
  """
  @spec shed([item()], integer(), keyword()) :: {[item()], [{item(), :shed_background_bound}]}
  def shed(items, now, opts \\ []) do
    cfg = config(opts)
    ranked = rank(items, now, opts)
    kept_all = Enum.map(ranked, &elem(&1, 0))
    background_ranked = Enum.filter(ranked, fn {i, _, _} -> i.lane == "background" end)

    excess = max(length(items) - cfg.shed_bound, 0)

    if excess == 0 do
      {kept_all, []}
    else
      # Lowest-ranked background items are the ones shed first.
      victims =
        background_ranked
        |> Enum.reverse()
        |> Enum.take(excess)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new(& &1.id)

      kept = Enum.reject(kept_all, &MapSet.member?(victims, &1.id))
      shed = for item <- kept_all, MapSet.member?(victims, item.id), do: {item, :shed_background_bound}
      {kept, shed}
    end
  end

  defp effective_lane(%{lane: "background"}, waited, cfg) when waited >= cfg.promote_after_seconds,
    do: "interactive"

  defp effective_lane(item, _waited, _cfg) do
    if Map.has_key?(@lane_weights, item.lane), do: item.lane, else: "background"
  end

  defp config(opts) do
    Map.merge(@defaults, Map.new(opts))
  end
end
