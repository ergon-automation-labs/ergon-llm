defmodule BotArmyLlm.ConversationStore do
  @moduledoc """
  In-memory conversation storage for the LLM bot.

  This GenServer maintains the in-memory state of all conversations while Ecto handles
  persistence to PostgreSQL. On init, it loads all conversations from the database.
  Every mutation (create, append_message, archive) is persisted to the database before updating state.

  ## API

  - `create/1` - Create a new conversation session
  - `get_session/1` - Retrieve a conversation by session_id
  - `append_message/2` - Add a message to a conversation
  - `archive/1` - Archive a conversation
  - `clear/0` - Clear all conversations (for testing)
  """

  use GenServer
  require Logger

  @server __MODULE__

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc """
  Create a new conversation session.

  Returns `{:ok, session_id, conversation}` or `{:error, reason}`.
  """
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @doc """
  Get a conversation session.

  Returns `{:ok, conversation}` or `{:error, :not_found}`.
  """
  def get_session(session_id) when is_binary(session_id) do
    GenServer.call(@server, {:get_session, session_id})
  end

  @doc """
  Append a message to a conversation.

  Message should have keys: "role" (user/assistant) and "content" (string).

  Returns `{:ok, updated_conversation}` or `{:error, reason}`.
  """
  def append_message(session_id, message) when is_binary(session_id) and is_map(message) do
    GenServer.call(@server, {:append_message, session_id, message})
  end

  @doc """
  Archive a conversation session.

  Returns `{:ok, archived_conversation}` or `{:error, reason}`.
  """
  def archive(session_id) when is_binary(session_id) do
    GenServer.call(@server, {:archive, session_id})
  end

  @doc """
  Clear all conversations (for testing).

  Returns `:ok`.
  """
  def clear do
    GenServer.call(@server, :clear)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Logger.info("ConversationStore started")
    # Load all conversations from database into GenServer state
    # Gracefully handle database unavailability (e.g., in tests)
    state = try do
      conversations = BotArmyLlm.Repo.all(BotArmyLlm.Schemas.Conversation)
      Enum.reduce(conversations, %{}, fn conv, acc ->
        Map.put(acc, conv.session_id |> to_string(), schema_to_map(conv))
      end)
    rescue
      _ ->
        Logger.warning("Could not load conversations from database (database unavailable). Starting with empty state.")
        %{}
    end
    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    session_id = Ecto.UUID.generate()

    changeset = BotArmyLlm.Schemas.Conversation.changeset(
      %BotArmyLlm.Schemas.Conversation{session_id: session_id},
      %{
        "session_id" => session_id,
        "messages" => [],
        "model" => Map.get(payload, "model", "auto"),
        "status" => "active"
      }
    )

    case BotArmyLlm.Repo.insert(changeset) do
      {:ok, db_conversation} ->
        conversation = schema_to_map(db_conversation)
        new_state = Map.put(state, session_id |> to_string(), conversation)
        Logger.info("Created conversation in database: #{session_id}")
        {:reply, {:ok, session_id |> to_string(), conversation}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create conversation: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case Map.get(state, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      conversation -> {:reply, {:ok, conversation}, state}
    end
  end

  @impl true
  def handle_call({:append_message, session_id, message}, _from, state) do
    case Map.get(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _conversation ->
        session_uuid = Ecto.UUID.cast!(session_id)
        db_conversation = BotArmyLlm.Repo.get_by(BotArmyLlm.Schemas.Conversation, session_id: session_uuid)

        if db_conversation do
          # Append message to messages list
          updated_messages = db_conversation.messages ++ [message]

          changeset = BotArmyLlm.Schemas.Conversation.changeset(
            db_conversation,
            %{"messages" => updated_messages}
          )

          case BotArmyLlm.Repo.update(changeset) do
            {:ok, updated_db_conversation} ->
              updated_conversation = schema_to_map(updated_db_conversation)
              new_state = Map.put(state, session_id, updated_conversation)
              Logger.info("Appended message to conversation: #{session_id}")
              {:reply, {:ok, updated_conversation}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to append message: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:archive, session_id}, _from, state) do
    case Map.get(state, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _conversation ->
        session_uuid = Ecto.UUID.cast!(session_id)
        db_conversation = BotArmyLlm.Repo.get_by(BotArmyLlm.Schemas.Conversation, session_id: session_uuid)

        if db_conversation do
          changeset = BotArmyLlm.Schemas.Conversation.changeset(
            db_conversation,
            %{"status" => "archived"}
          )

          case BotArmyLlm.Repo.update(changeset) do
            {:ok, archived_db_conversation} ->
              archived_conversation = schema_to_map(archived_db_conversation)
              new_state = Map.put(state, session_id, archived_conversation)
              Logger.info("Archived conversation: #{session_id}")
              {:reply, {:ok, archived_conversation}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to archive conversation: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all conversations")
    {:reply, :ok, %{}}
  end

  # Helper function to convert Ecto schema to map for GenServer state
  defp schema_to_map(%BotArmyLlm.Schemas.Conversation{} = conversation) do
    %{
      "session_id" => Ecto.UUID.cast!(conversation.session_id) |> to_string(),
      "messages" => conversation.messages || [],
      "model" => conversation.model,
      "status" => conversation.status,
      "created_at" => conversation.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => conversation.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end
