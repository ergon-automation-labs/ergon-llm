# BotArmyLlm

LLM (Large Language Model) operations bot implementation for the Bot Army ecosystem.

Manages prompt processing, model inference, and response handling.

## Building

```bash
mix deps.get
mix test
```

## Running

```bash
iex -S mix
```

## Architecture

- **NATS Consumer** - Listens for LLM-related messages
- **Prompt Processor** - Processes incoming prompts and queries
- **Inference Pipeline** - Manages model execution and responses

## Message Schemas

Schemas are defined in `bot_army_schemas_llm` and deployed to `/etc/bot_army/schemas/llm/`

## Dependencies

- `bot_army_core` - Core NATS decoder and envelope handling
- `nats` - NATS client library
- `jason` - JSON encoding/decoding
- `logger_json` - JSON logging

## Development

```bash
make setup    # Install dependencies
make test     # Run tests
make check    # Run all checks
```

## Related Repositories

- `bot_army_schemas_llm` - LLM message schemas
- `bot_army_core` - Core library
- `bot_army_infra` - Deployment infrastructure
