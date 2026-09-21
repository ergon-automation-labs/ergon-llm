defmodule BotArmyLlm.JobStore do
  @moduledoc """
  In-memory store for deferred (async) LLM jobs.

  An uncensored local model can take a minute or more to answer — that is a
  property of the model, not a fault. Blocking a NATS request/reply for that long
  forces every caller to guess a wall-clock deadline for work whose duration is
  unknowable, and a guess that is too small *silently* degrades the result (the
  caller gives up while the answer is still being computed).

  So a caller can ask for the request to be backgrounded instead:

      llm.request.chat  {"async": true, ...}   ->  {"job_id", "status": "accepted"}
      llm.job.status    {"job_id": ...}        ->  {"status": "pending" | "completed" | "failed", ...}

  The caller keeps its own budget for *polling*. A slow answer is then just slow;
  it is no longer a lost answer.

  Results are held in ETS owned by this GenServer and swept by age, mirroring the
  bridge's `JobStore` (same `job_id`/`status`/`result` shape) so operators have one
  job protocol to learn. Losing a job means a poll reports `job_not_found` and the
  caller falls back — it never means a wrong answer.
  """

  use GenServer
  require Logger

  @table :llm_job_store
  # Comfortably longer than a cold 27B generation, so a caller polling on its own
  # schedule always finds the result. Jobs are not a durable queue: a restart
  # forgets them, which is why every caller must treat `job_not_found` as
  # "unavailable", never as "done".
  @ttl_ms 60 * 60 * 1_000
  @sweep_interval_ms 5 * 60 * 1_000

  @type status :: :pending | :completed | :failed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a job as accepted. Returns the job id."
  @spec create(String.t(), map()) :: String.t()
  def create(job_id, meta \\ %{}) when is_binary(job_id) do
    ensure_table()
    now = System.system_time(:millisecond)

    entry = %{
      job_id: job_id,
      status: :pending,
      result: nil,
      error: nil,
      meta: meta,
      inserted_at: now,
      updated_at: now
    }

    :ets.insert(@table, {job_id, entry})
    job_id
  end

  @doc "Records a successful result."
  @spec complete(String.t(), term()) :: :ok
  def complete(job_id, result), do: update(job_id, :completed, result, nil)

  @doc "Records a failure. `error` must be a readable string for the caller."
  @spec fail(String.t(), term()) :: :ok
  def fail(job_id, error), do: update(job_id, :failed, nil, describe_error(error))

  @doc "Reads a job. `{:error, :not_found}` means unknown or already swept."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(job_id) when is_binary(job_id) do
    case safe_lookup(job_id) do
      [{^job_id, entry}] -> {:ok, entry}
      _ -> {:error, :not_found}
    end
  end

  def get(_other), do: {:error, :not_found}

  @doc "Drops jobs older than the TTL. Returns the number removed."
  @spec sweep(non_neg_integer()) :: non_neg_integer()
  def sweep(ttl_ms \\ @ttl_ms) do
    cutoff = System.system_time(:millisecond) - ttl_ms

    expired =
      :ets.foldl(
        fn {_id, entry}, acc ->
          if entry.inserted_at < cutoff, do: [entry.job_id | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  @doc "Counts jobs by status. For health/visibility."
  @spec counts() :: %{
          pending: non_neg_integer(),
          completed: non_neg_integer(),
          failed: non_neg_integer()
        }
  def counts do
    base = %{pending: 0, completed: 0, failed: 0}

    :ets.foldl(
      fn {_id, entry}, acc -> Map.update(acc, entry.status, 1, &(&1 + 1)) end,
      base,
      @table
    )
  end

  # -- server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    removed = sweep()

    if removed > 0 do
      Logger.debug("JobStore swept #{removed} expired LLM job(s)")
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- internals ------------------------------------------------------------

  defp update(job_id, status, result, error) when is_binary(job_id) do
    now = System.system_time(:millisecond)

    case safe_lookup(job_id) do
      [{^job_id, entry}] ->
        :ets.insert(
          @table,
          {job_id, %{entry | status: status, result: result, error: error, updated_at: now}}
        )

        :ok

      _ ->
        # A result for an unknown job is not an error for the worker that produced
        # it (the job was swept or the store restarted); log and move on.
        Logger.debug("JobStore update for unknown job #{job_id} (#{status})")
        :ok
    end
  end

  defp safe_lookup(job_id) do
    :ets.lookup(@table, job_id)
  rescue
    ArgumentError -> []
  end

  # Idempotent: the table may be absent when the store is used before its process
  # starts (or after a restart). Creating it here keeps a submission from crashing
  # the reply path.
  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp describe_error(error) when is_binary(error), do: error
  defp describe_error(error), do: inspect(error)
end
