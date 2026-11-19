defmodule BotArmyLlm.UncensoredTier do
  @moduledoc """
  The `light` and `heavy` options of the `:uncensored` type.

  `model_type: "uncensored"` promises a local model that will not refuse. A caller may also
  ask for how much of one it needs — `uncensored_tier: "light"` for a short, quick answer,
  `"heavy"` for the big one — and the models behind those names are the pillar's:
  the config key `OLLAMA_UNCENSORED_TIERS`, rendered by salt from `llm:uncensored_tiers`
  as a JSON object `{"light": {"model": "...", "node": ""}, "heavy": {...}}`. A blank node
  means the best local node; a named node pins the tier to the machine that holds its model.

  No model is named in code. A tier that is asked for and not configured is refused by name
  (`{:model_not_configured, {:uncensored, tier}}`) rather than answered by some other model: a
  silent swap changes the voice, the speed and what the answer costs, and nothing in the reply
  would say so. A caller that names no tier gets the type's single default, as before, and a
  caller that names a `model` itself keeps that model.
  """

  @tiers ~w(light heavy)

  @doc "The tiers a caller may ask for."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "Parse a caller-supplied tier to an atom. `:error` for anything not on the allowlist."
  @spec parse(term()) :: {:ok, :light | :heavy} | :error
  def parse(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "light" -> {:ok, :light}
      "heavy" -> {:ok, :heavy}
      _ -> :error
    end
  end

  def parse(value) when value in [:light, :heavy], do: {:ok, value}
  def parse(_value), do: :error

  @doc """
  Fill in the model and node for a request that asked for a tier.

  Only for `:uncensored`; any other complexity, or no tier, is returned untouched. A model
  or node the caller already named is kept.
  """
  @spec apply(keyword(), atom()) ::
          {:ok, keyword()} | {:error, {:model_not_configured, {:uncensored, atom()}}}
  def apply(opts, :uncensored) do
    case Keyword.get(opts, :uncensored_tier) do
      nil -> {:ok, opts}
      tier -> resolve(opts, tier)
    end
  end

  def apply(opts, _complexity), do: {:ok, opts}

  defp resolve(opts, tier) do
    case entry(tier) do
      {:ok, %{"model" => model, "node" => node}} ->
        opts =
          opts
          |> put_unless_named(:model, model)
          |> put_unless_named(:ollama_node, node)

        {:ok, opts}

      :error ->
        {:error, {:model_not_configured, {:uncensored, tier}}}
    end
  end

  defp put_unless_named(opts, key, value) do
    case Keyword.get(opts, key) do
      named when is_binary(named) and named not in ["", "auto"] -> opts
      _ -> if value in [nil, ""], do: opts, else: Keyword.put(opts, key, value)
    end
  end

  @doc "The configured entry for a tier, or `:error`."
  @spec entry(atom()) :: {:ok, %{String.t() => String.t()}} | :error
  def entry(tier) when tier in [:light, :heavy] do
    with raw when is_binary(raw) <-
           BotArmyLibraryRuntime.ConfigLoader.get("OLLAMA_UNCENSORED_TIERS"),
         {:ok, %{} = tiers} <- Jason.decode(raw),
         %{"model" => model} = found when is_binary(model) and model != "" <-
           Map.get(tiers, Atom.to_string(tier)) do
      {:ok, %{"model" => model, "node" => clean_node(found["node"])}}
    else
      _ -> :error
    end
  end

  defp clean_node(value) when is_binary(value), do: String.trim(value)
  defp clean_node(_value), do: ""
end
