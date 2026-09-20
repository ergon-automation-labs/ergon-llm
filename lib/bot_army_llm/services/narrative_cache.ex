defmodule BotArmyLlm.Services.NarrativeCache do
  @moduledoc """
  In-memory narrative cache for tasks.

  Stores generated narratives with validation hashes to detect when
  task/project/context has changed and cache needs refresh.

  Cache structure:
  ```
  %{
    task_id => %{
      "narrative" => {...},
      "cached_at" => timestamp,
      "valid_until" => timestamp,
      "input_hash" => hash_string,
      "context" => input_context_for_debugging
    }
  }
  ```
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @doc "Check if narrative cache is valid"
  def get_cached(task_id, current_input_hash) do
    GenServer.call(__MODULE__, {:get, task_id, current_input_hash})
  end

  @doc "Store generated narrative in cache"
  def put_cached(task_id, narrative, input_context, input_hash) do
    GenServer.cast(__MODULE__, {:put, task_id, narrative, input_context, input_hash})
  end

  @doc "Clear specific task cache"
  def invalidate(task_id) do
    GenServer.cast(__MODULE__, {:invalidate, task_id})
  end

  @doc "Clear all caches"
  def clear_all do
    GenServer.cast(__MODULE__, :clear_all)
  end

  # Server callbacks

  @impl true
  def handle_call({:get, task_id, current_input_hash}, _from, state) do
    case Map.get(state, task_id) do
      nil ->
        {:reply, {:miss, :not_found}, state}

      cached ->
        if is_cache_valid?(cached, current_input_hash) do
          {:reply, {:hit, cached["narrative"]}, state}
        else
          {:reply, {:miss, :stale}, state}
        end
    end
  end

  @impl true
  def handle_cast({:put, task_id, narrative, input_context, input_hash}, state) do
    cached_entry = %{
      "narrative" => narrative,
      "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "valid_until" => valid_until_iso(),
      "input_hash" => input_hash,
      "context" => input_context
    }

    Logger.debug(
      "Caching narrative for task #{task_id}, valid until #{cached_entry["valid_until"]}"
    )

    {:noreply, Map.put(state, task_id, cached_entry)}
  end

  @impl true
  def handle_cast({:invalidate, task_id}, state) do
    Logger.info("Invalidating narrative cache for task #{task_id}")
    {:noreply, Map.delete(state, task_id)}
  end

  @impl true
  def handle_cast(:clear_all, _state) do
    Logger.warning("Clearing all narrative caches")
    {:noreply, %{}}
  end

  # Helpers

  defp is_cache_valid?(cached, current_input_hash) do
    # Check hash match
    hash_matches = cached["input_hash"] == current_input_hash

    # Check expiration
    case DateTime.from_iso8601(cached["valid_until"]) do
      {:ok, expires_at, _} ->
        not_expired = DateTime.utc_now() < expires_at
        hash_matches and not_expired

      {:error, _} ->
        false
    end
  end

  defp valid_until_iso do
    DateTime.utc_now()
    |> DateTime.add(12 * 3600, :second)
    |> DateTime.to_iso8601()
  end
end
