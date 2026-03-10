# BotArmyLlm

LLM (Large Language Model) operations bot implementation for the Bot Army ecosystem.

Manages:
- Single-shot prompt completion
- Multi-step chained inference pipelines
- Multi-turn conversations with session tracking
- Response parsing with JSON extraction and retry logic
- Image analysis using vision models

## Features (v0.5.2+)

### 1. **Chain Inference** - Multi-Step Pipelines
Execute sequential steps where each step's output becomes the next step's input.
```
Step 1: "Analyze {input}" → output1
Step 2: "Summarize {input}" → output2
Result: [output1, output2, ...]
```

### 2. **Conversation** - Multi-Turn Sessions
Maintain session state across multiple exchanges with history-aware responses.
```
User: "Tell me about Elixir"
Assistant: [response using context from prior turns]
```

### 3. **Response Parsing** - JSON Extraction with Retry
Extract structured JSON from LLM responses with automatic correction on failure.
```
Input: "The answer is: {result: 42}" (wrapped in text)
Output: Extracted and validated {result: 42}
```

### 4. **Vision Analysis** - Image Understanding
Analyze images using vision models and optionally extract structured output.
```
Image + Prompt → LLM Vision Model → Raw Analysis + Optional JSON
```

## Building

```bash
mix deps.get
mix test
```

## Running

```bash
iex -S mix
```

## NATS Message Types

| Direction | Message | Handler | Purpose |
|-----------|---------|---------|---------|
| In | `llm.prompt.submit` | PromptHandler | Single-shot prompt completion |
| In | `llm.inference.chain` | InferenceHandler | Multi-step pipeline execution |
| In | `llm.inference.converse` | InferenceHandler | Multi-turn conversation |
| In | `llm.response.parse` | ResponseHandler | JSON extraction with retry |
| In | `llm.vision.analyze` | VisionHandler | Image analysis |
| Out | `llm.completion` | Publisher | Prompt completion result |
| Out | `llm.chain.step.completed` | Publisher | Chain step result |
| Out | `llm.chain.completed` | Publisher | Full chain result |
| Out | `llm.conversation.replied` | Publisher | Conversation response |
| Out | `llm.response.parsed` | Publisher | Parsed structured data |
| Out | `llm.vision.analyzed` | Publisher | Vision analysis result |
| Out | `llm.error` | Publisher | Error from any handler |

## Architecture

- **NATS Consumer** - Subscribes to 5 message types with routing
- **LlmClient** - Multi-provider routing with complexity-aware model selection
- **ConversationStore** - GenServer for session persistence
- **Handlers** - Specialized processors for each workflow
- **JsonExtractor** - Pure JSON parsing with fallback strategies

## Key Modules

- `lib/bot_army_llm/llm_client.ex` - Multi-provider LLM interface
- `lib/bot_army_llm/conversation_store.ex` - Session management
- `lib/bot_army_llm/json_extractor.ex` - JSON parsing & schema validation
- `lib/bot_army_llm/handlers/*.ex` - Message processing

## Database

Uses PostgreSQL for:
- Prompts & completions (from v0.5.0)
- Conversations & message history (from v0.5.2)

## Dependencies

- `bot_army_core` - NATS envelope decoding, schema validation
- `bot_army_runtime` - NATS connection management
- `nats` - NATS client library
- `jason` - JSON encoding/decoding
- `ecto_sql` - Database interface
- `postgrex` - PostgreSQL driver
- `logger_json` - Structured JSON logging

## Development

```bash
make setup          # Install dependencies
make test           # Run 56 tests
make check          # Run all checks (test + lint + dialyzer)
```

## Deployment

```bash
cd ../bot_army_infra
make deploy-bot BOT=llm
```

Pre-push hook automatically:
- Runs full test suite (56 tests)
- Compiles with warnings-as-errors
- Builds OTP release
- Publishes to GitHub
- Pushes to main

## Related Repositories

- `bot_army_schemas_llm` - LLM message schemas
- `bot_army_core` - Core library
- `bot_army_runtime` - Runtime library
- `bot_army_infra` - Deployment infrastructure

## Testing

```bash
mix test          # Run all 56 tests
mix test --cover  # With coverage report
mix credo         # Linting
```

Test modules:
- `json_extractor_test.exs` - 16 pure unit tests
- `inference_handler_test.exs` - 9 integration tests
- `response_handler_test.exs` - 8 integration tests
- `vision_handler_test.exs` - 8 integration tests
- `prompt_handler_test.exs` - 7 integration tests
- Plus 2 LlmClient tests

All tests use Application.put_env injection for mocking (no database required).
