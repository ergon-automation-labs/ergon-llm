# bot_army_llm Architecture Decisions

## Decision: Multi-Provider LLM Routing Strategy

**Date:** 2026-03-10
**Status:** Accepted
**Module:** BotArmyLlm.LlmClient
**Version:** 0.5.2+

**Problem:**
Single LLM provider creates vendor lock-in risk. Ollama may be unavailable, APIs may fail. Need graceful degradation.

**Decision:**
Implement provider chain routing:
- Standard completion: ollama → blackbox → openrouter → anthropic
- Multi-turn (complete_messages): same routing
- Vision analysis: ollama_vision → anthropic_vision → openrouter_vision

**Rationale:**
- Complexity-aware routing (ollama for simple, anthropic for complex)
- Graceful fallback if primary provider unavailable
- Cost optimization (use local ollama when applicable)
- Vendor independence (no single provider dependency)

**Alternatives Considered:**
- Single provider (openai) - rejected: vendor lock-in
- Load balancing - rejected: complexity, not needed for fallback
- User-specified provider - rejected: overhead, defaults better

**Implementation:**
- Each `complete_*` function tries providers in sequence
- Provider function returns `:error` on failure to trigger next attempt
- Last provider error is returned to caller as final failure
- Provider functions share common HTTP client patterns

**Related:**
- Parent GOVERNANCE.md → Core Principles → Event-Driven Architecture
- Documented patterns: memory/PATTERNS.md → Provider Routing Pattern

---

## Decision: ConversationStore for Session Persistence

**Date:** 2026-03-10
**Status:** Accepted
**Module:** BotArmyLlm.ConversationStore
**Version:** 0.5.2+

**Problem:**
Multi-turn conversations require session state management. Need to track message history across multiple NATS events. Database unavailability shouldn't crash the service.

**Decision:**
Create GenServer-based store following parent Store Pattern (see GOVERNANCE.md#store-pattern):
- In-memory map keyed by session_id
- Graceful DB fallback (log warning, start with empty state)
- Persist messages array to PostgreSQL conversations table
- Archive (soft-delete) conversations when session ends

**Rationale:**
- GenServer pattern matches existing PromptStore implementation
- In-memory cache provides fast reads without DB round-trips
- PostgreSQL persistence enables session replay and history
- Graceful degradation if DB unavailable on startup

**Alternatives Considered:**
- Pure database (no cache) - rejected: too slow, DB dependency
- Pure in-memory (no DB) - rejected: loses session history on restart
- Redis - rejected: adds infrastructure dependency, not needed

**Testing:**
- Mox pattern: inject mock ConversationStore in tests
- Application.put_env sets test mock during test setup
- No database access during handler tests

**Related:**
- Parent GOVERNANCE.md → Store Pattern → Initialization Pattern
- Parent GOVERNANCE.md → Testing Patterns → Handler Testing

---

## Decision: JSON Extraction with Fallback Strategy

**Date:** 2026-03-10
**Status:** Accepted
**Module:** BotArmyLlm.JsonExtractor
**Version:** 0.5.2+

**Problem:**
LLM responses are unstructured (prose + JSON). Different LLM providers format JSON differently:
- Some return raw JSON
- Some wrap in markdown fence (```json ... ```)
- Some interleave JSON within paragraph text

Single extraction strategy fails frequently.

**Decision:**
Implement three-step fallback extraction:
1. **Direct parsing** - Jason.decode on raw text
2. **Fence extraction** - Look for ```json fence, extract content
3. **Text extraction** - Search for first `{` or `[`, extract to matching bracket

**Rationale:**
- Handles varied LLM response formats from multiple providers
- Doesn't require provider-specific parsing logic
- Graceful degradation (try simpler methods first)
- Allows optional schema validation at any step

**Alternatives Considered:**
- Provider-specific parsing - rejected: maintainability, coupling
- LLM-guided extraction - rejected: overhead, slower
- Regex extraction - rejected: fragile, hard to maintain

**Trade-offs:**
- Slightly slower than single-pass (tries up to 3 methods)
- More robust than simple direct parsing

**Testing:**
- Pure unit tests (no mocks, no DB)
- Test extraction from: raw JSON, fence, embedded text
- Test schema validation: types, required fields, mismatches
- 16 comprehensive test cases

**Related:**
- Parent GOVERNANCE.md → Testing Patterns → Utility Testing (pure functions, no mocks)

---

## Decision: Vision Model Support via Provider Chain

**Date:** 2026-03-10
**Status:** Accepted
**Module:** BotArmyLlm.LlmClient.complete_vision/4
**Version:** 0.5.2+

**Problem:**
Multiple LLM providers support vision (image analysis) but with different API formats:
- Ollama: `images: [base64_data]` field
- Anthropic: Content array with base64 image source + type
- OpenRouter: OpenAI format with image_url content

Need unified interface for vision analysis.

**Decision:**
Implement `complete_vision/4` with provider chain (ollama_vision → anthropic_vision → openrouter_vision):
- Accept both base64 and URL image sources
- Provider-specific formatting (each handles its API format)
- Fallback chain if primary provider unavailable
- Optional JSON schema extraction on response (best-effort, doesn't error)

**Rationale:**
- Consistent with existing LlmClient routing strategy
- Fallback chain ensures availability
- Supports both image input formats (uploaded base64 + URL)
- JSON extraction optional (enables structured output or raw analysis)

**Env Vars:**
- OLLAMA_VISION_MODEL (default: "llava:latest")

**Related:**
- Parent GOVERNANCE.md → Core Principles → Dependency Injection
- Decision: Multi-Provider LLM Routing Strategy (above)

---

## Decision: EventBuilder Utility to Eliminate Duplication

**Date:** 2026-03-10
**Status:** Accepted
**Module:** BotArmyLlm.EventBuilder
**Version:** 0.5.2+

**Problem:**
Four new handlers (inference, response, vision, existing prompt) all build NATS event envelopes with identical structure:
```elixir
%{
  "event" => ...,
  "event_id" => UUID.uuid4(),
  "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
  "source" => "bot_army_llm",
  "source_node" => node() |> Atom.to_string(),
  "triggered_by" => "llm.bot",
  "schema_version" => "1.0",
  "payload" => ...
}
```

Duplicating 20 lines per handler (80 lines total).

**Decision:**
Create shared EventBuilder utility:
```elixir
def build(event_type, payload) do
  # Returns complete envelope with all metadata
end
```

**Rationale:**
- DRY principle: eliminate duplication across handlers
- Single source of truth for envelope structure
- Easier to add new metadata fields in future (request_id, trace_id, etc.)
- Ensures consistent formatting

**Alternatives Considered:**
- Macro-based approach - rejected: less testable, harder to debug
- Protocol-based - rejected: overkill for simple case

**Impact:**
- All handlers import EventBuilder
- 20 lines of duplication eliminated per handler
- New message types can easily use same builder

**Related:**
- Parent GOVERNANCE.md → Handler Pattern → private publishing

---

## Decision: Conversation.complete_messages/2 to Support Multi-Turn

**Date:** 2026-03-10
**Status:** Accepted
**Module:** BotArmyLlm.LlmClient
**Version:** 0.5.2+

**Problem:**
Existing `complete/2` accepts raw text. Multi-turn conversations need full message history (system, user, assistant messages with roles). Can't build this on top of text-based API.

**Decision:**
Add `complete_messages/2(messages_list, opts)` that:
- Accepts pre-built messages array (role + content pairs)
- Routes through same provider chain as `complete/2`
- Each provider formats messages for its API
- Returns same response format as `complete/2`

**Rationale:**
- Maintains backward compatibility (complete/2 unchanged)
- Reuses existing provider routing infrastructure
- Each provider (ollama, openai-compatible, anthropic) already accepts messages arrays
- Enables InferenceHandler (chain) and conversation support

**Implementation:**
- Refactored internal HTTP calls to accept `messages` parameter
- Each provider (ollama, openai-compatible, anthropic) has `*_messages` variant
- Falls back to original `complete/2` implementation if no messages variant available

**Related:**
- Parent GOVERNANCE.md → Core Principles → Dependency Injection (handlers depend on injected LlmClient)

---

## Decision: Mox Testing Without Database Access

**Date:** 2026-03-10
**Status:** Accepted
**Testing Pattern:** All new handlers
**Version:** 0.5.2+

**Problem:**
Handler tests need to call ConversationStore and LlmClient, but running tests requires PostgreSQL SSH tunnel (unavailable in CI, slows local iteration).

**Decision:**
Use Mox pattern with Application.put_env/3 injection:

```elixir
defmodule TestLlmClientMock do
  def complete(text, _opts) when is_binary(text) do
    Process.get({:test_llm_client_response}, {:error, :not_configured})
  end
end

test "handler processes message" do
  Application.put_env(:bot_army_llm, :llm_client, TestLlmClientMock)

  # Configure per-test mock response
  Process.put({:test_llm_client_response}, {:ok, %{...}})

  # Handler uses injected mock, no DB access needed
  assert ... = Handler.handle_action(message)
end
```

**Rationale:**
- No database connection needed (tests don't start Ecto repo)
- Fast test execution (100% in-memory)
- Can easily mock failures (test error handling)
- Matches parent testing strategy (see GOVERNANCE.md#testing-patterns)

**Alternatives Considered:**
- Real database in tests - rejected: slow, requires infrastructure setup
- Gherkin/integration tests - rejected: overkill, slower feedback loop
- Database transactions + rollback - rejected: still requires DB connection

**Test Modules:**
- inference_handler_test.exs: Tests chain and conversation with mocks
- response_handler_test.exs: Tests JSON extraction + retry logic
- vision_handler_test.exs: Tests image analysis with mocks
- json_extractor_test.exs: Pure unit tests (no mocks)
- prompt_handler_test.exs: Existing tests (updated for atom keys)

**Related:**
- Parent GOVERNANCE.md → Testing Patterns → Handler Testing (with Mocks)
- Parent GOVERNANCE.md → Core Principles → Dependency Injection

---

## Decision: Prompt Bug Fix (String Keys → Atom Keys)

**Date:** 2026-03-10
**Status:** Fixed
**File:** lib/bot_army_llm/handlers/prompt_handler.ex
**Lines:** 104-110, 122-130
**Version:** 0.5.1 → 0.5.2

**Problem:**
PromptHandler was accessing response with string keys (`response["completion"]`), but LlmClient returns atom keys (`response.completion`). Type mismatch causes runtime failures.

**Decision:**
Update PromptHandler to use atom key access:
- `response["completion"]` → `response.completion`
- `response["model_used"]` → `response.model_used`
- `response["tokens_input"]` → `response.tokens_input`
- `response["tokens_output"]` → `response.tokens_output`
- `response["latency_ms"]` → `response.latency_ms`

Also update test mock to return atom keys matching real LlmClient format.

**Rationale:**
- Matches LlmClient return format (existing contract)
- Prevents runtime errors
- All new handlers also use atom keys

**Impact:**
- PromptHandler now correctly accesses LlmClient response
- Tests pass with correct mock format

**Related:**
- LlmClient.complete/2 return format (atom keys)
- All new handlers follow same pattern

