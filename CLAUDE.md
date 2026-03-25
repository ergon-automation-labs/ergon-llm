# CLAUDE.md

Guidance for Claude Code when working with `bot_army_llm`.

---

## Parent Framework

This repo follows the architecture and patterns defined in the parent governance framework:

**[→ See parent GOVERNANCE.md](/code/elixir_bots/GOVERNANCE.md)**

Key sections:
- **Core Principles** - Event-driven NATS, Ecto persistence, dependency injection
- **NATS Message Pattern** - Standard envelope structure for all messages
- **Handler Pattern** - Validation → processing → publishing pattern used by all handlers
- **Store Pattern** - GenServer-based data persistence (ConversationStore follows this pattern)
- **Testing Patterns** - Mox mocking for isolation, no DB access in tests

Repo-specific decisions are documented in `memory/DECISIONS.md` with parent references.

---

## Purpose

**bot_army_llm** is the LLM (Large Language Model) operations bot implementation.

Handles:
- Single-shot prompt submission and completion
- Multi-step chained inference pipelines
- Multi-turn conversations with session tracking
- Response parsing with JSON extraction and retry logic
- Image analysis using vision models

---

## File Organization

```
.
├── lib/
│   ├── bot_army_llm.ex                    # Main module
│   └── bot_army_llm/
│       ├── application.ex                  # Application supervisor
│       ├── llm_client.ex                   # Multi-provider LLM routing
│       ├── prompt_store.ex                 # Prompt persistence GenServer
│       ├── conversation_store.ex           # Conversation session GenServer (v0.5.2+)
│       ├── json_extractor.ex               # JSON extraction & validation (v0.5.2+)
│       ├── event_builder.ex                # NATS event envelope creation (v0.5.2+)
│       ├── complexity_scorer.ex            # Prompt complexity heuristics
│       ├── ollama_health_checker.ex        # Ollama node availability checker
│       ├── repo.ex                         # Ecto database connection
│       ├── nats/
│       │   ├── consumer.ex                 # NATS message consumer
│       │   └── publisher.ex                # NATS message publisher
│       ├── schemas/
│       │   ├── prompt.ex                   # Ecto schema for prompts
│       │   ├── completion.ex               # Ecto schema for completions
│       │   └── conversation.ex             # Ecto schema for conversations (v0.5.2+)
│       └── handlers/
│           ├── prompt_handler.ex           # Single-shot prompt handler
│           ├── inference_handler.ex        # Chain & converse workflows (v0.5.2+)
│           ├── response_handler.ex         # JSON parsing with retry (v0.5.2+)
│           └── vision_handler.ex           # Image analysis handler (v0.5.2+)
├── priv/
│   └── repo/
│       └── migrations/
│           ├── 20260301000001_create_prompts.exs
│           ├── 20260301000002_create_completions.exs
│           └── 20260310000003_create_conversations.exs (v0.5.2+)
├── test/
│   ├── test_helper.exs
│   └── bot_army_llm/
│       ├── llm_client_test.exs
│       ├── json_extractor_test.exs         (v0.5.2+)
│       └── handlers/
│           ├── prompt_handler_test.exs
│           ├── inference_handler_test.exs  (v0.5.2+)
│           ├── response_handler_test.exs   (v0.5.2+)
│           └── vision_handler_test.exs     (v0.5.2+)
├── config/
│   ├── config.exs
│   ├── runtime.exs
│   └── test.exs
├── mix.exs
├── README.md
├── SETUP.md
├── CLAUDE.md
├── .gitignore
└── memory/
    ├── MEMORY.md                # Session summaries
    ├── DECISIONS.md             # Architectural decisions with parent links
    └── PATTERNS.md              # Repo-specific code patterns
```

---

## Core Dependencies

- **bot_army_core** - NATS envelope decoding, schema validation
- **nats** - NATS client for message publishing/subscribing
- **jason** - JSON encoding/decoding
- **logger_json** - Structured JSON logging

The bot depends on schemas deployed by `bot_army_schemas_llm` at `/etc/bot_army/schemas/llm/`

---

## Development Workflow

### Setup

```bash
mix deps.get
mix test
```

### Key Modules

**Implemented (v0.5.2+):**

1. **BotArmyLlm.LlmClient** - Multi-provider LLM routing with complexity-aware selection
   - Routes through: ollama → blackbox → openrouter → anthropic
   - `complete/2` - Single-shot completion
   - `complete_messages/2` - Multi-turn with message history
   - `complete_vision/4` - Image analysis (v0.5.2+)

2. **BotArmyLlm.ConversationStore** - Session management
   - In-memory + PostgreSQL persistence
   - Stores message history per session

3. **BotArmyLlm.JsonExtractor** - JSON parsing (v0.5.2+)
   - Direct parsing → fence extraction → text extraction
   - Schema validation

4. **BotArmyLlm.NATS.Consumer** - Message routing
   - Subscribes to 5 message types
   - Routes to appropriate handlers

5. **BotArmyLlm.Handlers.PromptHandler** - Single-shot prompts
   - Validates payload, calls LLM, persists result

6. **BotArmyLlm.Handlers.InferenceHandler** - Multi-step & multi-turn (v0.5.2+)
   - `handle_chain/1` - Chained inference with template interpolation
   - `handle_converse/1` - Multi-turn conversations with session tracking

7. **BotArmyLlm.Handlers.ResponseHandler** - Response parsing (v0.5.2+)
   - JSON extraction with retry logic
   - Corrective LLM prompts on failure

8. **BotArmyLlm.Handlers.VisionHandler** - Image analysis (v0.5.2+)
   - Base64 & URL image support
   - Optional schema-based JSON extraction

### Message Subjects (Incoming)

```
llm.prompt.submit          → PromptHandler.handle_submit/1
llm.inference.chain        → InferenceHandler.handle_chain/1
llm.inference.converse     → InferenceHandler.handle_converse/1
llm.response.parse         → ResponseHandler.handle_parse/1
llm.vision.analyze         → VisionHandler.handle_analyze/1
```

### Message Subjects (Outgoing)

```
events.llm.completion                              # From PromptHandler (fallback, no source_domain)
events.llm.completion.{bot_name}.{request_type}   # From PromptHandler (typed completions)
  Example: events.llm.completion.job_applications.cover_letter
  bot_name: derived by stripping "bot_army_" prefix from envelope source
  request_type: source_metadata["source_domain"]

events.llm.chain.step.completed    # From InferenceHandler (chain)
events.llm.chain.completed         # From InferenceHandler (chain)
events.llm.conversation.replied    # From InferenceHandler (converse)
events.llm.response.parsed         # From ResponseHandler
events.llm.vision.analyzed         # From VisionHandler
events.llm.error                   # From any handler on error
```

All messages follow the core envelope structure from `bot_army_core`.

---

## Testing

```bash
mix test                    # Run all 56 tests
mix test --cover            # With coverage report
mix credo                   # Linting
mix dialyzer                # Static analysis
mix compile --warnings-as-errors  # Strict compilation
```

### Test Modules (v0.5.2+)

- **json_extractor_test.exs** - 16 pure unit tests (no mocks)
  - JSON extraction from various formats
  - Schema validation logic

- **inference_handler_test.exs** - 9 integration tests
  - Chain execution: happy path, failure mid-chain
  - Conversation: new session, existing session, missing fields
  - Mock pattern: `Application.put_env(:bot_army_llm, :llm_client, MockModule)`

- **response_handler_test.exs** - 8 integration tests
  - Direct JSON parsing
  - Schema validation and mismatch handling
  - Retry logic with corrective prompts
  - Max retries exhaustion

- **vision_handler_test.exs** - 8 integration tests
  - Base64 image analysis
  - URL-based image analysis
  - Optional schema parsing
  - Error handling

- **prompt_handler_test.exs** - 7 integration tests
  - Existing single-shot prompt tests

**Test Pattern:** All handler tests use `Application.put_env/3` injection with inline mock modules defined in test files. No database access required during handler tests (ConversationStore behavior can be mocked).

---

## Deployment

### Automatic (Pre-Push Hook)

When pushing to main branch, the git pre-push hook automatically:
1. Runs `mix deps.get`
2. Runs full test suite (56 tests must pass)
3. Compiles with `--warnings-as-errors`
4. Builds OTP release with `mix release`
5. Creates version-stamped tarball
6. Publishes to GitHub releases
7. Proceeds with push only if all checks pass

### Manual Deployment

Deploy to Air node via Salt:

```bash
cd ../bot_army_infra
make deploy-bot BOT=llm
```

This will:
1. Pull latest release tarball from GitHub
2. Deploy via Salt to Air node
3. Restart llm_proxy service
4. Run health checks

### Database Migrations

First deployment of v0.5.2+ will run migrations:
```
20260310000003_create_conversations.exs
```

This creates the conversations table for session storage.

### Prerequisites

1. Core schemas deployed (bot_army_schemas_llm)
2. bot_army_core library deployed
3. PostgreSQL with SSH tunnel to port 30003
4. NATS broker available on configured host:port

---

## Related Repositories

- `bot_army_schemas_llm` - LLM message schemas
- `bot_army_core` - Core library and NATS decoder
- `bot_army_infra` - Deployment infrastructure

---

## Agent Workflow Pattern

**Effective use of Claude Code agents when developing this bot.**

This follows the polyrepo agent strategy documented in `bot_army_infra/CLAUDE.md`.

### When to Use Haiku Agents

- Exploring bot implementation patterns and existing handlers
- Reading test files to understand expected behavior
- Diagnostics: checking test failures, understanding error logs
- Code search: finding where specific functionality is implemented
- Verification: running tests, confirming deployments

**Why**: Fast iteration loop (seconds vs minutes), perfect for read-heavy tasks and diagnostics.

### When to Use Sonnet Agents

- Implementing new handlers or features
- Designing multi-provider routing logic (as in llm_client.ex)
- Validating architecture before writing code
- Refactoring existing handlers
- Complex integrations with external APIs

**Why**: Deep reasoning ensures features are designed correctly, multi-file changes are coherent, and edge cases are handled.

### Example: Add New Provider to LLM Client

```
User: "Add Mistral API support to llm_client"
  ↓
1. Haiku (Explore): Read existing providers (blackbox, openrouter, anthropic)
   Understand provider pattern and error handling
  ↓
2. Sonnet (Plan): Design Mistral provider module
   Identify config changes, integration points, test cases
  ↓
3. Sonnet (Implement): Write provider module, update router, add tests
  ↓
4. Haiku (Verify): Run test suite, check for syntax errors
```
