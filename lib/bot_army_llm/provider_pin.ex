defmodule BotArmyLlm.ProviderPin do
  @moduledoc """
  Choosing the provider, and the model, for a request — instead of walking the default chain.

  Three ways in, in order of strength:

    1. **The request names it.** `"provider": "openrouter"` (one provider, no fallback) or
       `"provider": ["openrouter", "anthropic"]` (these, in this order), and optionally a
       `"model"` that the pillar allows for that provider.
    2. **The caller's route.** `LLM_ROUTES`, rendered from `llm:routes`, maps a calling bot's name to
       defaults: `{"rss_polling": {"provider": "local_ollama"}}`. A route fills in only what the
       request left out, so a request that names a provider always wins over its route.
    3. **Neither**: the default chain, exactly as before.

  Nothing here widens what a request may reach. A pinned provider must already be in the chain the
  request would have walked, or be local: the chain is where the safety and uncensored rules are
  decided (sensitive text is local-only, `:uncensored` is `[:ollama]`), and a pin that could step
  around them would be a way to send that text to a cloud model. A model for a cloud provider must be
  on that provider's pillar allowlist (`LLM_PROVIDER_MODELS`); an unlisted one is refused by name,
  never swapped for another. With a model named, the pin must be a single provider, because a model
  name belongs to one provider.

  Nothing is named in code: the provider allowlist is the set the bot implements, and every model,
  route and default comes from config.
  """

  @providers ~w(ollama local_ollama openrouter anthropic blackbox)
  @local [:ollama, :local_ollama]
  @route_keys ~w(provider model model_type uncensored_tier)

  @type error ::
          {:unknown_provider, term()}
          | {:provider_not_allowed, atom()}
          | {:model_not_allowed, String.t(), atom(), [String.t()]}
          | {:model_needs_single_provider, String.t()}

  @doc "The providers a request may name."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc "Parse a request's `provider` field. A string or a list of strings; anything else is `:error`."
  @spec parse(term()) :: {:ok, [atom()]} | :error
  def parse(value) when is_binary(value), do: parse([value])

  def parse([_ | _] = list) do
    parsed = Enum.map(list, &parse_one/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(parsed, &elem(&1, 1))},
      else: :error
  end

  def parse(_value), do: :error

  defp parse_one(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "ollama" -> {:ok, :ollama}
      "local_ollama" -> {:ok, :local_ollama}
      "openrouter" -> {:ok, :openrouter}
      "anthropic" -> {:ok, :anthropic}
      "blackbox" -> {:ok, :blackbox}
      _ -> :error
    end
  end

  defp parse_one(_value), do: :error

  @doc """
  Apply a request's pin to the chain it would have walked.

  `chain` is the provider list the safety and type rules produced. Returns the chain unchanged when
  nothing is pinned, the pinned list when it is allowed, or `{:error, reason}`.
  """
  @spec resolve([atom()], keyword()) :: [atom()] | {:error, error()}
  def resolve(chain, opts) do
    case Keyword.get(opts, :providers) do
      nil -> chain
      {:invalid, value} -> {:error, {:unknown_provider, value}}
      pinned when is_list(pinned) -> check(pinned, chain, opts)
    end
  end

  defp check(pinned, chain, opts) do
    with :ok <- check_allowed(pinned, chain) do
      check_model(pinned, Keyword.get(opts, :model))
    end
    |> case do
      :ok -> pinned
      {:error, _} = error -> error
    end
  end

  defp check_allowed(pinned, chain) do
    case Enum.find(pinned, &(&1 not in @local and &1 not in chain)) do
      nil -> :ok
      provider -> {:error, {:provider_not_allowed, provider}}
    end
  end

  defp check_model(_pinned, model) when model in [nil, "", "auto"], do: :ok

  defp check_model([provider], model) when is_binary(model) do
    if provider in @local do
      :ok
    else
      allowed = allowed_models(provider)

      if model in allowed,
        do: :ok,
        else: {:error, {:model_not_allowed, model, provider, allowed}}
    end
  end

  defp check_model(_many, model), do: {:error, {:model_needs_single_provider, model}}

  @doc "Whether a pinned request named a model that this cloud provider should use."
  @spec model_for(atom(), keyword()) :: String.t() | nil
  def model_for(provider, opts) do
    model = Keyword.get(opts, :model)

    if provider not in @local and match?([_], Keyword.get(opts, :providers)) and
         is_binary(model) and model not in ["", "auto"] and model in allowed_models(provider),
       do: model
  end

  @doc "The pillar's allowlist of models a caller may name for a provider; `[]` when none."
  @spec allowed_models(atom()) :: [String.t()]
  def allowed_models(provider) do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get("LLM_PROVIDER_MODELS"),
         {:ok, %{} = by_provider} <- Jason.decode(raw),
         [_ | _] = models <- Map.get(by_provider, Atom.to_string(provider)) do
      Enum.filter(models, &(is_binary(&1) and &1 != ""))
    else
      _ -> []
    end
  end

  @doc "The route configured for a calling bot, as a map with only the known keys; `%{}` when none."
  @spec route_for(term()) :: map()
  def route_for(bot) when is_binary(bot) and bot != "" do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get("LLM_ROUTES"),
         {:ok, %{} = routes} <- Jason.decode(raw),
         %{} = route <- Map.get(routes, bot) do
      Map.take(route, @route_keys)
    else
      _ -> %{}
    end
  end

  def route_for(_bot), do: %{}
end
