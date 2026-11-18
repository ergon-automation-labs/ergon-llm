defmodule BotArmyLlm.TriageAdmission do
  @moduledoc """
  The seam between the chat request path and the triage queue.

  Off by default (`config :bot_army_llm, triage_enabled: false`). When on, a sync
  chat request is admitted to `BotArmyLlm.TriageQueue` as a unit of work instead of
  running immediately; the queue runs it later in priority order and the reply goes
  out from there.

  Request fields the queue reads (all optional):

    * `"sender"` — `"user"`, `"system"`, or `"automated"`; default `"system"`.
    * `"model_type"` — `"uncensored"` pins the request to local (`local_only`).
    * `"cloud_only"` — `true` marks a request that needs a cloud model; it waits in
      triage mode. Only an explicit flag does this, so no model name is guessed.

  Token estimate is the encoded payload size / 4, which is rough but good enough to
  keep large requests from jumping the line within a lane.
  """

  alias BotArmyLlm.TriageQueue

  @senders %{"user" => :user, "system" => :system, "automated" => :automated}

  @doc "Whether the triage queue is enabled for this node."
  def enabled?, do: Application.get_env(:bot_army_llm, :triage_enabled, false) == true

  @doc """
  Admit one request. `work` is a zero-arity function that runs the request and
  publishes its reply. Returns `:ok`.
  """
  @spec admit(map(), String.t(), (-> any())) :: :ok
  def admit(payload, lane, work) when is_map(payload) and is_function(work, 0) do
    TriageQueue.enqueue(build_item(payload, lane, work))
  end

  @doc "Build the queue item for a request. Pure; exposed for tests."
  def build_item(payload, lane, work) do
    %{
      id: to_string(Map.get(payload, "request_id") || System.unique_integer([:positive])),
      lane: lane,
      sender: Map.get(@senders, Map.get(payload, "sender"), :system),
      est_tokens: div(byte_size(Jason.encode!(payload)), 4),
      local_only: Map.get(payload, "model_type") == "uncensored",
      cloud_only: Map.get(payload, "cloud_only") == true,
      work: work
    }
  end
end
