defmodule BotArmyLlm.Config do
  @moduledoc """
  The one way this bot reads configuration.

  ## Why this exists

  This bot runs under launchd, which does **not** put the service's settings into
  the process environment. The salt template renders them into a file instead —
  `/etc/bot_army/llm_proxy.config.exs` — and says so in its own header: it exists
  "to avoid relying on BotArmyLlm.Config.get() which doesn't work with launchd env vars".

  `BotArmyLibraryRuntime.ConfigLoader.get/2` reads that file first and falls back
  to the environment. `System.get_env/1` reads only the environment, so under
  launchd it returns `nil` for every setting the pillar actually delivered.

  Reading `System.get_env/1` directly is therefore not "the same thing, a bit
  shorter" — it is a different question, and it answers wrong. Measured
  2026-10-07: `:blackbox` and `:anthropic` reported `:provider_not_configured`
  while their API keys sat correctly in that file, because those two call sites
  used `System.get_env/1` and `:openrouter` — the one that used `ConfigLoader` —
  got as far as a real HTTP call. Every request that could not be served by
  local Ollama fell off the end of the chain as `:no_providers_available`, and
  callers saw "LLM providers are temporarily unavailable".

  ## Blank means unset

  The template writes `""` for a pillar entry that was never set. A blank string
  is truthy in Elixir, so reading it raw would defeat the caller's default and
  turn "not configured" into a confusing 401 from the provider. Blank is treated
  as absent here, which is what "the pillar did not set this" actually means.

  ## Guarantees

  Strict superset of `System.get_env/2`: a key present in the config file wins,
  otherwise the environment is consulted, otherwise `default`. Values are
  returned as written — this module does no type coercion, so callers that parse
  strings, booleans or integers keep doing so.
  """

  @doc """
  Read `key`, with an optional `default` used when it is missing or blank.

  ## Examples

      iex> BotArmyLlm.Config.get("__unset_key__", "fallback")
      "fallback"

  """
  @spec get(String.t(), any()) :: any()
  def get(key, default \\ nil) when is_binary(key) do
    case BotArmyLibraryRuntime.ConfigLoader.get(key) do
      nil ->
        default

      value when is_binary(value) ->
        if String.trim(value) == "", do: default, else: value

      value ->
        value
    end
  end
end
