defmodule BotArmyLlm.ModelType do
  @moduledoc """
  The model types a caller may ask for by name, and what each one promises.

  Four types, in two kinds:

    * **`:light`, `:medium`, `:heavy`** — complexity tiers. They answer "how hard
      is this prompt?", and a tier may be served by Ollama, blackbox, OpenRouter
      or Anthropic, whichever is healthy and cheapest.
    * **`:uncensored`** — a *family*, not a difficulty. It answers "this content
      must not be refused". A model that refuses is not a slower answer, it is
      no answer, so the promise is: served by a **local** model named in the
      pillar (`llm:ollama:models:uncensored`), never by a cloud provider that
      would substitute a policy for the content. `LlmClient` enforces that in two
      independent places (the provider chain and the cloud model lookup), because
      the failure mode — silently answering an intimate register with a censored
      cloud model — is invisible in the reply.

  Callers pass a type as a string in a payload or an atom in opts; both are
  parsed here and validated against the allowlist. An unrecognised type is
  `:error`, never a new atom (`String.to_atom/1` on caller input is how a fleet
  grows a thousand atoms).
  """

  @types [:light, :medium, :heavy, :uncensored]
  @local_only @types -- [:light, :medium, :heavy]

  @doc "Every type a caller may ask for."
  @spec all() :: [atom()]
  def all, do: @types

  @doc """
  Parse a caller-supplied type. `:error` for anything not on the allowlist —
  including `nil`, which means "no type requested".
  """
  @spec parse(atom() | String.t() | nil) :: {:ok, atom()} | :error
  def parse(type) when type in @types, do: {:ok, type}

  def parse(type) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "light" -> {:ok, :light}
      "medium" -> {:ok, :medium}
      "heavy" -> {:ok, :heavy}
      "uncensored" -> {:ok, :uncensored}
      _ -> :error
    end
  end

  def parse(_type), do: :error

  @doc "Parse a type, or fall back to `default` (used when scoring a prompt)."
  @spec parse_or(atom() | String.t() | nil, atom()) :: atom()
  def parse_or(type, default) do
    case parse(type) do
      {:ok, parsed} -> parsed
      :error -> default
    end
  end

  @doc "True when the type may only be served by a local model."
  @spec local_only?(atom()) :: boolean()
  def local_only?(type), do: type in @local_only
end
