defmodule BotArmyLlm.NATS.EngagementConsumer do
  @moduledoc """
  NATS consumer for engagement events published by Nova narrative system.

  Listens to engagement event subjects and stores them in the database
  for downstream learning and analytics.

  Subscription subjects:
  - events.narrative.shown - Narrative displayed to user
  - events.narrative.completed - Task completed successfully
  - events.narrative.skipped - Narrative skipped by user
  - events.narrative.abandoned - Task abandoned by user
  """

  use GenServer
  require Logger

  alias BotArmyLlm.Services.EngagementEventStore
  alias BotArmyLibraryRuntime.NATS.Connection

  @reconnect_delay_ms 5000
  @subjects [
    "events.narrative.shown",
    "events.narrative.completed",
    "events.narrative.skipped",
    "events.narrative.abandoned"
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("EngagementConsumer starting")
    {:ok, %{}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    case Connection.conn() do
      {:ok, conn} ->
        Logger.info("Subscribing to engagement event subjects: #{inspect(@subjects)}")

        Enum.each(@subjects, fn subject ->
          case Gnat.sub(conn, self(), subject) do
            {:ok, _subscription_id} ->
              Logger.info("Subscribed to #{subject}")

            {:error, reason} ->
              Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
          end
        end)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to get NATS connection: #{inspect(reason)}")
        Process.send_after(self(), :retry_subscribe, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    case Jason.decode(msg.body) do
      {:ok, event_map} ->
        handle_engagement_event(event_map)

      {:error, reason} ->
        Logger.error("Failed to decode engagement event: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:retry_subscribe, state) do
    {:noreply, state, {:continue, :subscribe}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warn("NATS connection lost, will attempt to resubscribe")
    Process.send_after(self(), :retry_subscribe, @reconnect_delay_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_engagement_event(event_map) do
    case EngagementEventStore.store_event(event_map) do
      {:ok, event} ->
        Logger.debug(
          "Stored engagement event: #{event.event_type} for task #{event.task_id}, user #{event.user_id}, voice #{event.voice_key}"
        )

      {:error, changeset} ->
        Logger.error("Failed to store engagement event: #{inspect(changeset.errors)}")
    end
  end
end
