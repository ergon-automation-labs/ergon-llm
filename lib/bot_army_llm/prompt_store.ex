defmodule BotArmyLlm.PromptStore do
  @moduledoc """
  In-memory prompt storage for the LLM bot.

  This GenServer maintains the in-memory state of all prompts while Ecto handles
  persistence to PostgreSQL. On init, it loads all prompts from the database.
  Every mutation (create, update) is persisted to the database before updating state.

  ## API

  - `create/1` - Create a new prompt
  - `update/2` - Update an existing prompt
  - `archive/1` - Archive a prompt
  - `get/1` - Retrieve a prompt by ID
  - `list/0` - List all active prompts
  - `list_all/0` - List all prompts including archived
  """

  use GenServer
  alias BotArmyLlm.{Prompt, Repo}
  require Logger

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new prompt from payload.

  Returns `{:ok, prompt}` with the created prompt, or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Update an existing prompt.

  Returns `{:ok, prompt}` with the updated prompt, or `{:error, reason}`.
  """
  def update(prompt_id, payload) when is_binary(prompt_id) and is_map(payload) do
    GenServer.call(@server, {:update, prompt_id, payload})
  end

  @doc """
  Archive a prompt.

  Returns `{:ok, prompt}` with the archived prompt, or `{:error, reason}`.
  """
  def archive(prompt_id) when is_binary(prompt_id) do
    GenServer.call(@server, {:archive, prompt_id})
  end

  @doc """
  Retrieve a prompt by ID.

  Returns `{:ok, prompt}` or `{:error, :not_found}`.
  """
  def get(prompt_id) when is_binary(prompt_id) do
    GenServer.call(@server, {:get, prompt_id})
  end

  @doc """
  List all active prompts.

  Returns `{:ok, prompts}`.
  """
  def list do
    GenServer.call(@server, :list)
  end

  @doc """
  List all prompts including archived.

  Returns `{:ok, prompts}`.
  """
  def list_all do
    GenServer.call(@server, :list_all)
  end

  @doc """
  Clear all prompts (for testing).

  Returns `:ok`.
  """
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PromptStore started")
    # Load all prompts from database into GenServer state
    # Gracefully handle database unavailability (e.g., in tests)
    state =
      try do
        prompts = Repo.all(BotArmyLlm.Schemas.Prompt)

        Enum.reduce(prompts, %{}, fn prompt, acc ->
          Map.put(acc, prompt.id |> to_string(), schema_to_map(prompt))
        end)
      rescue
        _ ->
          Logger.warning(
            "Could not load prompts from database (database unavailable). Starting with empty state."
          )

          %{}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    prompt_id = Ecto.UUID.generate()

    changeset =
      BotArmyLlm.Schemas.Prompt.changeset(
        %BotArmyLlm.Schemas.Prompt{id: prompt_id},
        %{
          "text" => payload["text"],
          "model" => payload["model"],
          "temperature" => Map.get(payload, "temperature", 0.7),
          "max_tokens" => Map.get(payload, "max_tokens"),
          "status" => "active"
        }
      )

    case Repo.insert(changeset) do
      {:ok, db_prompt} ->
        prompt = schema_to_map(db_prompt)
        new_state = Map.put(state, prompt_id, prompt)
        Logger.info("Created prompt in database: #{prompt_id}")
        {:reply, {:ok, prompt}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create prompt: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, prompt_id, payload}, _from, state) do
    case Map.get(state, prompt_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _prompt ->
        perform_update(prompt_id, payload, state)
    end
  end

  @impl true
  def handle_call({:archive, prompt_id}, _from, state) do
    case Map.get(state, prompt_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _prompt ->
        perform_archive(prompt_id, state)
    end
  end

  @impl true
  def handle_call({:get, prompt_id}, _from, state) do
    case Map.get(state, prompt_id) do
      nil -> {:reply, {:error, :not_found}, state}
      prompt -> {:reply, {:ok, prompt}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    prompts =
      state
      |> Map.values()
      |> Enum.filter(fn p -> p["status"] == "active" end)

    {:reply, {:ok, prompts}, state}
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    prompts = Map.values(state)
    {:reply, {:ok, prompts}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all prompts")
    {:reply, :ok, %{}}
  end

  defp perform_update(prompt_id, payload, state) do
    prompt_uuid = Ecto.UUID.cast!(prompt_id)
    db_prompt = Repo.get(BotArmyLlm.Schemas.Prompt, prompt_uuid)

    if db_prompt do
      changeset =
        BotArmyLlm.Schemas.Prompt.changeset(
          db_prompt,
          %{
            "text" => Map.get(payload, "text", db_prompt.text),
            "model" => Map.get(payload, "model", db_prompt.model),
            "temperature" => Map.get(payload, "temperature", db_prompt.temperature),
            "max_tokens" => Map.get(payload, "max_tokens", db_prompt.max_tokens)
          }
        )

      handle_update_result(changeset, prompt_id, state)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  defp handle_update_result(changeset, prompt_id, state) do
    case Repo.update(changeset) do
      {:ok, updated_db_prompt} ->
        updated_prompt = schema_to_map(updated_db_prompt)
        new_state = Map.put(state, prompt_id, updated_prompt)
        Logger.info("Updated prompt in database: #{prompt_id}")
        {:reply, {:ok, updated_prompt}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to update prompt: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  defp perform_archive(prompt_id, state) do
    prompt_uuid = Ecto.UUID.cast!(prompt_id)
    db_prompt = Repo.get(BotArmyLlm.Schemas.Prompt, prompt_uuid)

    if db_prompt do
      changeset =
        BotArmyLlm.Schemas.Prompt.changeset(
          db_prompt,
          %{"status" => "archived"}
        )

      handle_archive_result(changeset, prompt_id, state)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  defp handle_archive_result(changeset, prompt_id, state) do
    case Repo.update(changeset) do
      {:ok, archived_db_prompt} ->
        archived_prompt = schema_to_map(archived_db_prompt)
        new_state = Map.put(state, prompt_id, archived_prompt)
        Logger.info("Archived prompt in database: #{prompt_id}")
        {:reply, {:ok, archived_prompt}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to archive prompt: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%BotArmyLlm.Schemas.Prompt{} = prompt) do
    %{
      "id" => Ecto.UUID.cast!(prompt.id) |> to_string(),
      "text" => prompt.text,
      "model" => prompt.model,
      "temperature" => prompt.temperature,
      "max_tokens" => prompt.max_tokens,
      "status" => prompt.status,
      "created_at" => prompt.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => prompt.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end
