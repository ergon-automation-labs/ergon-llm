# CLAUDE.md

Guidance for Claude Code when working with `bot_army_llm`.

---

## Purpose

**bot_army_llm** is the LLM (Large Language Model) operations bot implementation.

Handles:
- Prompt submission and processing
- Model inference execution
- Response parsing and handling
- Error management and retries

---

## File Organization

```
.
├── lib/
│   ├── bot_army_llm.ex                  # Main module
│   └── bot_army_llm/
│       ├── application.ex                # Application supervisor
│       ├── nats/
│       │   └── consumer.ex               # NATS message consumer
│       └── handlers/
│           ├── prompt_handler.ex
│           ├── inference_handler.ex
│           └── response_handler.ex
├── test/
│   ├── test_helper.exs
│   └── bot_army_llm/
│       ├── nats/
│       │   └── consumer_test.exs
│       └── handlers/
│           └── prompt_handler_test.exs
├── mix.exs
├── CLAUDE.md
└── README.md
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

### Key Modules to Implement

1. **BotArmyLlm.NATS.Consumer** - Subscribe to NATS subjects
2. **BotArmyLlm.Handlers.PromptHandler** - Process prompt messages
3. **BotArmyLlm.Handlers.InferenceHandler** - Handle inference operations
4. **BotArmyLlm.Handlers.ResponseHandler** - Parse and handle responses

### Message Subjects

The bot listens to and publishes:
- `llm.prompt.*` - Prompt operations
- `llm.model.*` - Model operations
- `llm.response.*` - Response handling

All messages follow the core envelope structure from `bot_army_core`.

---

## Testing

```bash
mix test                    # Run all tests
mix test --cover            # With coverage
mix credo                   # Linting
mix dialyzer                # Static analysis
```

---

## Deployment

This bot is deployed via Salt from `bot_army_infra`:

```bash
cd ../bot_army_infra
make deploy-bot BOT=llm
```

Deployment happens after:
1. Core schemas deployed
2. bot_army_core library deployed

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
