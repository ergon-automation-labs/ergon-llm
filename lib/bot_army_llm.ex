defmodule BotArmyLlm do
  @moduledoc """
  BotArmyLlm is the LLM (Large Language Model) operations bot implementation.

  Handles LLM-based processing, prompt management, and model inference
  within the Bot Army ecosystem.

  ## Schemas

  Message schemas are defined in `bot_army_schemas_llm` and deployed to:
  `/etc/bot_army/schemas/llm/`

  The bot consumes messages from NATS subjects like:
  - `llm.prompt.submit` - Submit prompt for processing
  - `llm.model.infer` - Run inference
  - `llm.response.process` - Process LLM response
  """

  @version "0.1.0"

  def version do
    @version
  end
end
