# bot_army_llm Code Patterns & Conventions

## Handler Pattern

All handlers follow the validation → processing → publishing pattern defined in parent GOVERNANCE.md#handler-pattern.

### Structure

```elixir
defmodule BotArmyLlm.Handlers.YourHandler do
  @moduledoc """
  Handles specific message type.
  Processes: event.name
  Dependencies: Services, Publisher
  """

  require Logger

  # Dependency injection
  defp service do
    Application.get_env(:bot_army_llm, :your_service, BotArmyLlm.YourService)
  end

  def handle_action(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_payload(payload) do
      :ok -> process_action(payload, event_id, message)
      {:error, reason} -> publish_error(event_id, reason, "Validation failed")
    end
  end

  # Private validation
  defp validate_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "required_field") do
      :ok
    end
  end

  defp validate_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  # Private processing
  defp process_action(payload, event_id, _message) do
    case service().process(payload) do
      {:ok, result} ->
        Logger.info("Action processed: event_id=#{event_id}")
        publish_success(result, event_id)

      {:error, reason} ->
        Logger.error("Action failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Processing failed")
    end
  end

  # Private publishing
  defp publish_success(result, event_id) do
    event = EventBuilder.build("llm.action.completed", %{
      "result" => result,
      "triggered_by_event_id" => event_id
    })

    case Publisher.publish(event) do
      :ok -> Logger.debug("Published success event")
      {:error, reason} -> Logger.error("Failed to publish: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message) do
    event = EventBuilder.build("llm.error", %{
      "error" => message,
      "reason" => inspect(reason),
      "triggered_by_event_id" => event_id
    })

    case Publisher.publish(event) do
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end
```

### Key Points

- **Validation**: Returns `:ok` or `{:error, reason}` tuple
- **Processing**: Calls injected service, handles both success and error cases
- **Publishing**: Uses EventBuilder for consistent envelope structure
- **Error Handling**: Always publishes `llm.error` event with original event_id
- **Logging**: Info on success, error on failure, debug on publishing

---

## Testing Pattern: Handler with Mocks

All handler tests use Application.put_env/3 injection for mocking:

```elixir
defmodule YourHandlerTest do
  use ExUnit.Case

  # Define inline mock module
  defmodule TestServiceMock do
    def process(payload) do
      Process.get({:your_service_mock, :response}, {:error, :not_configured})
    end
  end

  setup do
    # Inject mock before test
    Application.put_env(:bot_army_llm, :your_service, TestServiceMock)

    # Restore after test
    on_exit(fn ->
      Application.put_env(:bot_army_llm, :your_service, BotArmyLlm.YourService)
    end)

    :ok
  end

  test "handler succeeds when service returns ok" do
    # Configure mock per-test
    Process.put({:your_service_mock, :response}, {:ok, %{"result" => "value"}})

    message = %{
      "event_id" => "test-event-id",
      "payload" => %{"required_field" => "value"}
    }

    assert :ok = YourHandler.handle_action(message)
    # Verify published event by checking Logger output
  end

  test "handler publishes error when service fails" do
    Process.put({:your_service_mock, :response}, {:error, :service_error})

    message = %{
      "event_id" => "test-event-id",
      "payload" => %{"required_field" => "value"}
    }

    assert :ok = YourHandler.handle_action(message)
  end

  test "handler validates payload" do
    message = %{
      "event_id" => "test-event-id",
      "payload" => %{}  # Missing required_field
    }

    assert :ok = YourHandler.handle_action(message)
  end
end
```

### Key Points

- **Mock per handler**: Define inline `TestServiceMock` or `TestLlmClientMock` etc.
- **Per-test config**: Use `Process.put` to configure mock response for each test
- **No DB access**: Tests don't connect to database
- **Restore on exit**: Use `on_exit` callback to reset Application config
- **No assertions on publishing**: Publishing side-effects verified through logs (Logger captures)

---

## Provider Routing Pattern

All `complete_*` functions in LlmClient use provider chain routing:

```elixir
def complete(text, opts) when is_binary(text) do
  providers = [:ollama, :blackbox, :openrouter, :anthropic]
  try_providers(providers, text, opts)
end

defp try_providers([provider | rest], text, opts) do
  case apply_provider(provider, text, opts) do
    {:ok, result} -> {:ok, result}
    {:error, _} -> try_providers(rest, text, opts)
  end
end

defp try_providers([], _text, _opts) do
  {:error, :no_providers_available}
end

defp apply_provider(:ollama, text, opts), do: ollama_call(text, opts)
defp apply_provider(:blackbox, text, opts), do: blackbox_call(text, opts)
# etc.
```

### Vision Provider Chain

Vision models have same pattern but different provider list:
- `[:ollama_vision, :anthropic_vision, :openrouter_vision]`

Each provider-specific function:
1. **Validates prerequisites** (e.g., base64 image provided, not just URL)
2. **Formats request** for provider's API
3. **Calls HTTP** and handles network errors
4. **Returns atom-key response** (completion, model_used, tokens_input, tokens_output, latency_ms)

### Key Points

- **Graceful fallback**: Try next provider on any error
- **Provider independence**: Single failure doesn't block system
- **Complexity-aware routing**: Simple prompts use local ollama first
- **Consistent response format**: All providers return same shape

---

## JSON Extraction Pattern

JsonExtractor implements three-step fallback strategy:

```elixir
def extract(text) when is_binary(text) do
  case try_direct_extraction(text) do
    {:ok, data} -> {:ok, data}
    :error ->
      case try_fence_extraction(text) do
        {:ok, data} -> {:ok, data}
        :error -> try_text_extraction(text)
      end
  end
end

defp try_direct_extraction(text) do
  case Jason.decode(text) do
    {:ok, data} -> {:ok, data}
    :error -> :error
  end
end

defp try_fence_extraction(text) do
  case Regex.run(~r/```(?:json)?\s*\n([\s\S]*?)\n```/i, text) do
    [_, json_text] ->
      case Jason.decode(json_text) do
        {:ok, data} -> {:ok, data}
        :error -> :error
      end

    nil -> :error
  end
end

defp try_text_extraction(text) do
  case find_json_bracket(text) do
    {:ok, json_text} ->
      case Jason.decode(json_text) do
        {:ok, data} -> {:ok, data}
        :error -> {:error, :no_json_found}
      end

    :error -> {:error, :no_json_found}
  end
end
```

### Optional Schema Validation

```elixir
def validate_schema(data, nil), do: :ok

def validate_schema(data, schema) when is_map(schema) do
  case schema do
    %{"type" => "object"} -> is_map(data) && :ok || {:error, :schema_mismatch}
    %{"type" => "array"} -> is_list(data) && :ok || {:error, :schema_mismatch}
    # Check required fields, types, etc.
  end
end
```

### Key Points

- **Three fallback strategies**: Direct → Fence → Text extraction
- **Handles varied LLM formats**: Raw JSON, markdown fence, embedded in text
- **Optional validation**: Schema checking is optional (some use cases don't need it)
- **Graceful degradation**: Returns error if all three methods fail

---

## NATS Event Envelope Pattern

All events published to NATS use EventBuilder to create consistent envelopes:

```elixir
EventBuilder.build("llm.action.completed", %{
  "result" => result_data,
  "triggered_by_event_id" => original_event_id
})

# Returns:
%{
  "event" => "llm.action.completed",
  "event_id" => "550e8400-e29b-41d4-a716-446655440000",  # UUID
  "timestamp" => "2026-03-10T12:34:56.789Z",              # ISO8601 UTC
  "source" => "bot_army_llm",
  "source_node" => "nonode@nohost",
  "triggered_by" => "llm.bot",
  "schema_version" => "1.0",
  "payload" => %{
    "result" => result_data,
    "triggered_by_event_id" => original_event_id
  }
}
```

### Correlation Pattern

Always include `triggered_by_event_id` in payload to enable tracing:
- Allows downstream systems to correlate response with original request
- Enables audit trails and debugging
- Creates implicit message ID correlation

### Error Envelopes

All errors use `llm.error` event:

```elixir
EventBuilder.build("llm.error", %{
  "error" => "Human readable error message",
  "reason" => "error_code or reason",
  "triggered_by_event_id" => original_event_id
})
```

---

## ConversationStore Pattern

GenServer-based session storage following parent Store Pattern:

```elixir
defmodule BotArmyLlm.ConversationStore do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Gracefully handle DB unavailability
    state = try do
      load_from_db()
    rescue
      _ ->
        Logger.warning("DB unavailable on startup, starting with empty conversations")
        %{}
    end
    {:ok, state}
  end

  def create(payload) do
    GenServer.call(__MODULE__, {:create, payload})
  end

  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get, session_id})
  end

  def append_message(session_id, message) do
    GenServer.call(__MODULE__, {:append, session_id, message})
  end

  def archive(session_id) do
    GenServer.call(__MODULE__, {:archive, session_id})
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    session_id = UUID.uuid4()
    conversation = %{
      "session_id" => session_id,
      "messages" => [],
      "model" => payload["model"],
      "status" => "active"
    }

    new_state = Map.put(state, session_id |> to_string(), conversation)
    persist_to_db(conversation)

    {:reply, {:ok, conversation}, new_state}
  end

  # Similar for get, append, archive, clear...
end
```

### Key Points

- **GenServer pattern**: Manages state concurrently
- **Graceful DB fallback**: Logs warning, continues if DB unavailable on startup
- **In-memory + persistent**: Fast reads from cache, durable storage in DB
- **Session lifecycle**: Create, get, append messages, archive when done

---

## Dependency Injection Pattern

All external service dependencies injected via Application.get_env/3:

```elixir
# In handler
defp llm_client do
  Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)
end

defp conversation_store do
  Application.get_env(:bot_army_llm, :conversation_store, BotArmyLlm.ConversationStore)
end

# In test
Application.put_env(:bot_army_llm, :llm_client, TestLlmClientMock)
Application.put_env(:bot_army_llm, :conversation_store, TestConversationStoreMock)
```

### Benefits

- **No coupling to implementations**: Handler calls `llm_client()`, not `BotArmyLlm.LlmClient`
- **Easy testing**: Inject mocks for any test
- **Environment-specific config**: Different impls in dev/prod/test
- **Graceful degradation**: Can provide stub implementations

---

## Message History Format

Multi-turn conversations store messages as array of maps:

```elixir
[
  %{"role" => "system", "content" => "You are a helpful assistant."},
  %{"role" => "user", "content" => "First question"},
  %{"role" => "assistant", "content" => "Answer to first question"},
  %{"role" => "user", "content" => "Follow-up question"},
  %{"role" => "assistant", "content" => "Answer to follow-up"}
]
```

### Roles

- **system**: Initial instructions/context (optional)
- **user**: User message
- **assistant**: LLM response

### Storage

- Stored in PostgreSQL `conversations.messages` column (array of maps)
- Loaded into ConversationStore on init
- Appended to array on each new message

