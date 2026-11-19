defmodule BotArmyLlm.ExecutionLane do
  @moduledoc """
  Where a completed request actually ran: cloud or local.

  A caller cannot infer this from `model_type` alone. `heavy` usually routes to a
  cloud provider, but the provider chain may fall back; `light` and `medium` may
  be served locally. The resolved provider and model are the honest evidence, so
  this module names the lane once, at the reply boundary.

  Callers use the lane to choose a deadline, not to choose who may answer:
  `model_type: "uncensored"` is a local-only *policy* promise, while the lane is
  only a speed and placement fact.

  Ollama's cloud models carry a `-cloud` or `:cloud` suffix. That is a useful
  hint, but it is not the whole answer: `anthropic`, `openrouter`, and `blackbox`
  are cloud by provider even when their model names have no suffix.
  """

  @lanes ~w(cloud local unknown)
  @cloud_providers ~w(blackbox openrouter anthropic)
  @local_providers ~w(ollama local_ollama local_fallback deterministic_fallback)
  @cloud_suffixes ["-cloud", ":cloud"]

  @doc "Every lane this module can report."
  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  @doc """
  Classify one completed call from its provider and model.

  Returns `"cloud"`, `"local"`, or `"unknown"`. A missing provider and a model
  with no known marker stay unknown rather than being guessed as local.
  """
  @spec classify(atom() | String.t() | nil, String.t() | nil) :: String.t()
  def classify(provider, model_used) do
    provider = provider_name(provider)

    cond do
      provider in @cloud_providers ->
        "cloud"

      provider in @local_providers ->
        if cloud_model_name?(model_used), do: "cloud", else: "local"

      cloud_model_name?(model_used) ->
        "cloud"

      true ->
        "unknown"
    end
  end

  @doc "Classify a `llm.request.chat` / `llm.job.status` result map."
  @spec from_result(map()) :: String.t()
  def from_result(result) when is_map(result) do
    classify(Map.get(result, "provider"), Map.get(result, "model_used"))
  end

  @doc "True when an Ollama model name carries the cloud marker."
  @spec cloud_model_name?(String.t() | nil) :: boolean()
  def cloud_model_name?(model) when is_binary(model) do
    Enum.any?(@cloud_suffixes, &String.ends_with?(model, &1))
  end

  def cloud_model_name?(_model), do: false

  defp provider_name(nil), do: nil
  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_name(provider) when is_binary(provider), do: String.downcase(provider)
  defp provider_name(_provider), do: nil
end
