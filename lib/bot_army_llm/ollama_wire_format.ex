defmodule BotArmyLlm.OllamaWireFormat do
  @moduledoc false
  # Ollama chat can be routed through the headroom context-optimization proxy by
  # switching to the OpenAI-compatible /v1/chat/completions wire format (headroom's
  # anyllm backend speaks OpenAI, not native /api/chat). When OLLAMA_WIRE_FORMAT=openai,
  # chat calls hit chat_url()/v1/chat/completions; on a hard headroom failure (5xx or
  # connection error) the caller re-encodes to the native ollama body and retries
  # ollama_url()/api/chat directly. Anything other than "openai" (incl. unset/bad
  # values) resolves to :native, so the switch is inert unless explicitly enabled.

  @spec wire_format() :: :native | :openai
  def wire_format do
    case BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_WIRE_FORMAT", "native")
         |> String.downcase() do
      "openai" -> :openai
      _ -> :native
    end
  end

  @doc false
  # OpenAI-format chat endpoint. Defaults to OLLAMA_URL (the native ollama node)
  # when OLLAMA_CHAT_URL is unset, so the openai branch is a no-op wire change unless
  # OLLAMA_CHAT_URL points at headroom (e.g. http://127.0.0.1:8790).
  def chat_url do
    BotArmyLibraryRuntime.ConfigLoader.get(
      "OLLAMA_CHAT_URL",
      BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_URL", "http://localhost:11434")
    )
  end

  @doc false
  # Native ollama node URL, used for the direct fallback when headroom is down.
  def ollama_url do
    BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_URL", "http://localhost:11434")
  end
end
