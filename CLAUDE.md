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
