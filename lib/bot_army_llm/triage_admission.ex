defmodule BotArmyLlm.TriageAdmission do
  @moduledoc """
  The seam between the chat request path and the triage queue.

  Off by default (`config :bot_army_llm, triage_enabled: false`). When on, a sync
  chat request is admitted to `BotArmyLlm.TriageQueue` instead of running at once.

  If the request is still queued after `triage_ack_after_ms` (default 8000, keep it
  below the callers' timeout), the caller gets a queued reply instead of silence:

      %{"ok" => true, "status" => "queued", "request_id" => id, "job_id" => id,
        "retry_after_ms" => ..., "poll_subject" => "llm.job.status", "message" => "..."}

  The answer is then stored as a job under `job_id`, which is the request id, so it can
  be looked up later with `llm.job.status`. Whichever side claims the request first
  decides who answers: a request dispatched before the timer goes straight to the
  caller; one still waiting when the timer fires is answered by ack and finished as
  a job.

  Request fields the queue reads (all optional):

    * `"request_id"` — also the job id for queued requests.
    * `"sender"` — `"user"`, `"system"`, or `"automated"`; default `"system"`.
    * `"model_type"` — `"uncensored"` pins the request to local (`local_only`).
    * `"cloud_only"` — `true` marks a request that needs a cloud model; it waits in
      triage mode. Only an explicit flag does this, so no model name is guessed.

  Token estimate is the encoded payload size / 4, which is rough but good enough to
  keep large requests from jumping the line within a lane.
  """

  require Logger

  alias BotArmyLlm.{JobBell, JobStore, TriageQueue}

  @senders %{"user" => :user, "system" => :system, "automated" => :automated}
  @default_ack_after_ms 8_000
  @retry_after_ms 30_000

  @doc "Whether the triage queue is enabled for this node."
  def enabled? do
    default = Application.get_env(:bot_army_llm, :triage_enabled, false) == true

    case BotArmyLibraryRuntime.ConfigLoader.get("TRIAGE_ENABLED", nil) do
      nil -> default
      value -> String.downcase(to_string(value)) in ["true", "1", "yes"]
    end
  end

  @doc """
  Admit one request.

    * `reply` — `fn map -> :ok end`, publishes a reply to the caller.
    * `compute` — `fn -> map end`, runs the request and returns its reply map.
    * `server` / `ack_after_ms` — optional, for tests.

  Returns `:ok`.
  """
  @spec admit(map(), String.t(), keyword()) :: :ok
  def admit(payload, lane, opts) when is_map(payload) do
    reply = Keyword.fetch!(opts, :reply)
    compute = Keyword.fetch!(opts, :compute)
    server = Keyword.get(opts, :server, TriageQueue)
    ack_after = Keyword.get(opts, :ack_after_ms, ack_after_ms())

    id = request_id(payload)
    work = fn -> run_work(id, reply, compute, server) end
    item = build_item(payload, lane, work) |> Map.put(:id, id)

    :ok = TriageQueue.enqueue(server, item)
    Task.start(fn -> maybe_ack(id, lane, reply, server, ack_after) end)
    :ok
  end

  @doc "Build the queue item for a request. Pure; exposed for tests."
  def build_item(payload, lane, work) do
    %{
      id: request_id(payload),
      lane: lane,
      sender: Map.get(@senders, Map.get(payload, "sender"), :system),
      est_tokens: div(byte_size(Jason.encode!(payload)), 4),
      local_only: Map.get(payload, "model_type") == "uncensored",
      cloud_only: Map.get(payload, "cloud_only") == true,
      work: work
    }
  end

  @doc "The queued reply a caller gets when its request has waited past the ack window."
  def ack_map(id, lane) do
    %{
      "ok" => true,
      "status" => "queued",
      "request_id" => id,
      "job_id" => id,
      "lane" => lane,
      "retry_after_ms" => @retry_after_ms,
      "poll_subject" => "llm.job.status",
      "message" =>
        "The system is busy with higher-priority work, so your request is queued and will " <>
          "run when traffic is lower. Look it up with llm.job.status using job_id " <>
          "#{id}, or ask again with this request_id once retry_after_ms has passed."
    }
  end

  defp run_work(id, reply, compute, server) do
    try do
      if TriageQueue.claim(server, id, :dispatch) do
        reply.(compute.())
      else
        # The caller already has a queued reply; the answer goes to the job store.
        result = compute.()
        JobStore.complete(id, result)
        JobBell.ring(id, "completed")
      end
    rescue
      error ->
        Logger.error("[TriageAdmission] request #{id} failed: #{Exception.message(error)}")
        JobStore.fail(id, Exception.message(error))
        JobBell.ring(id, "failed")
    end
  end

  defp maybe_ack(id, lane, reply, server, ack_after) do
    Process.sleep(ack_after)

    if TriageQueue.claim(server, id, :ack) do
      JobStore.create(id, %{subject: "chat", lane: lane, request_id: id, queued: true})
      reply.(ack_map(id, lane))
    end

    :ok
  end

  defp request_id(payload) do
    case Map.get(payload, "request_id") do
      id when is_binary(id) and id != "" -> id
      _ -> UUID.uuid4()
    end
  end

  defp ack_after_ms do
    Application.get_env(:bot_army_llm, :triage_ack_after_ms, @default_ack_after_ms)
  end
end
