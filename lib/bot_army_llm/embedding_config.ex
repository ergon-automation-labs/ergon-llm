defmodule BotArmyLlm.EmbeddingConfig do
  @moduledoc """
  Runtime embedding settings for RAG (`llm.rag.*`), `llm.embed.request`, and `LlmClient.embed/2`.

  Configured via environment variables (see `bot_army_infra/salt/bots/llm_bot.sls` and
  `pillar/air-secrets.sls` `llm.embed`):

  | Env | Role |
  |-----|------|
  | `BOT_ARMY_LLM_EMBED_DEFAULT_MODEL` | Ollama `/api/embed` model when the caller omits `model`. |
  | `BOT_ARMY_LLM_OPENROUTER_EMBED_DEFAULT_MODEL` | OpenRouter embeddings model when the caller omits `model`. If unset or empty, falls back to `default_model/0` (same id as Ollama). |
  | `OLLAMA_EMBED_TIMEOUT_MS` | HTTP recv timeout for Ollama `/api/embed`. |
  | `OPENROUTER_EMBEDDINGS_URL` | Full URL for OpenRouter embeddings POST. |
  | `OPENROUTER_EMBED_TIMEOUT_MS` | HTTP timeout for OpenRouter embeddings. |
  """

  @default_model "nomic-embed-text"
  @default_openrouter_embeddings_url "https://openrouter.ai/api/v1/embeddings"

  @doc "Default Ollama embedding model when NATS payload or `LlmClient.embed/2` omits `model`."
  def default_model do
    System.get_env("BOT_ARMY_LLM_EMBED_DEFAULT_MODEL") || @default_model
  end

  @doc """
  OpenRouter embedding model when the caller omits `model`.

  Set `BOT_ARMY_LLM_OPENROUTER_EMBED_DEFAULT_MODEL` to a different slug than Ollama (e.g. OpenAI
  embeddings on OpenRouter). If unset, uses `default_model/0` so both providers tried the same id.
  """
  def openrouter_embed_default_model do
    case System.get_env("BOT_ARMY_LLM_OPENROUTER_EMBED_DEFAULT_MODEL") do
      nil -> default_model()
      "" -> default_model()
      m when is_binary(m) -> m
    end
  end

  @doc """
  Normalizes NATS `model` field: `nil` or blank → `nil` (use per-provider defaults in `LlmClient.embed/2`);
  otherwise the same model id is sent to Ollama and OpenRouter.
  """
  def optional_explicit_model(nil), do: nil
  def optional_explicit_model(""), do: nil
  def optional_explicit_model(m) when is_binary(m), do: m

  @doc "HTTP timeout (ms) for Ollama `POST .../api/embed`."
  def ollama_embed_timeout_ms do
    parse_timeout_ms(System.get_env("OLLAMA_EMBED_TIMEOUT_MS"), 120_000)
  end

  @doc "Full URL for OpenRouter-compatible embeddings API."
  def openrouter_embeddings_url do
    System.get_env("OPENROUTER_EMBEDDINGS_URL") || @default_openrouter_embeddings_url
  end

  @doc "HTTP timeout (ms) for OpenRouter embeddings request."
  def openrouter_embed_timeout_ms do
    parse_timeout_ms(System.get_env("OPENROUTER_EMBED_TIMEOUT_MS"), 30_000)
  end

  defp parse_timeout_ms(nil, default), do: default

  defp parse_timeout_ms(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end
end
