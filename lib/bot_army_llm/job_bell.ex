defmodule BotArmyLlm.JobBell do
  @moduledoc """
  Rings when a backgrounded (`async`) chat job reaches a terminal state.

  A caller that asked for a job instead of a blocking reply has two ways to learn
  the job finished: ask again (`llm.job.status`), or be told. Being told costs one
  message instead of hundreds, which is what lets a caller hold a waiter for an
  hour — the life of the job in `BotArmyLlm.JobStore` — without spending that
  hour asking.

  The bell deliberately carries **nothing worth stealing**: a job id and whether
  the job completed or failed. Not the words, not the provider's error text. A
  subscriber that wants either fetches it by id over the request/reply subject,
  so a completion event cannot spray somebody's private answer across every bot
  on the bus.

  Two rules make the bell safe to rely on:

  * **It is rung after the store write, never before.** A caller woken by a bell
    that arrived early would read `pending`, go back to sleep, and wait for a
    second bell that is not coming.
  * **It is a courtesy, not the protocol.** `JobStore` is the truth; a bell that
    cannot be rung is logged and dropped, and the caller still finds the result on
    its own cadence. A caller must never treat a missing bell as a missing job.
  """

  require Logger

  alias BotArmyLlm.EventBuilder
  alias BotArmyLlm.NATS.Publisher

  @event "llm.job.completed"
  @statuses ~w(completed failed)

  @doc "The event name. The wire subject is derived from it by the publisher."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  Rings for one finished job.

  `status` is `"completed"` or `"failed"` — the two states a waiting caller can
  act on. Anything else is refused rather than published, so a bell always means
  something definite.
  """
  @spec ring(String.t(), String.t()) :: :ok | {:error, term()}
  def ring(job_id, status) when is_binary(job_id) and status in @statuses do
    event = EventBuilder.build(@event, %{"job_id" => job_id, "status" => status})

    case publisher().publish(event) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Could not ring the bell for job #{job_id}: #{inspect(reason)}")
        error
    end
  rescue
    # A courtesy must not be able to take a job down with it.
    error ->
      Logger.warning("Could not ring the bell for job #{job_id}: #{Exception.message(error)}")
      {:error, :bell_failed}
  end

  def ring(job_id, status) when is_binary(job_id), do: {:error, {:unknown_status, status}}

  defp publisher, do: Application.get_env(:bot_army_llm, :nats_publisher, Publisher)
end
