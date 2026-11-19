defmodule BotArmyLlm.LocalOllama do
  @moduledoc """
  The `local_ollama` source: local Ollama models the caller names, on a breaker of
  their own, with a deadline and a line long enough for a batch of async jobs.

  It is a provider like `ollama`, `blackbox` and `anthropic`, but it is selected by
  the caller (`"source": "local_ollama"`), never by the default chain, and it never
  falls back to another provider. Its failures and 429s cannot open the default
  `ollama` breaker, and the default chain's cannot open this one.

  ## Models are the pillar's to name

  No model is named in code. `LOCAL_OLLAMA_MODELS` (rendered by salt from
  `llm:local_ollama:models`) is a JSON list of `{"model": "...", "node": "mini"}`;
  the first entry is the default model and a `null`/absent node means the best
  local node. With no list the source fails closed (`:model_not_configured`)
  rather than substituting a model. Numeric limits are config too:
  `LOCAL_OLLAMA_TIMEOUT_MS`, `LOCAL_OLLAMA_MAX_TIMEOUT_MS`, `LOCAL_OLLAMA_MAX_WAITING`.
  """

  @default_timeout_ms 180_000
  @max_timeout_ms 600_000
  @default_waiting 64

  @doc "The configured `%{\"model\", \"node\"}` entries, default first; `[]` when unset or unreadable."
  @spec models() :: [map()]
  def models do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get("LOCAL_OLLAMA_MODELS"),
         {:ok, [_ | _] = list} <- Jason.decode(raw),
         true <- Enum.all?(list, &(is_map(&1) and is_binary(&1["model"]) and &1["model"] != "")) do
      Enum.map(list, &%{"model" => &1["model"], "node" => blank_to_nil(&1["node"])})
    else
      _ -> []
    end
  end

  @doc """
  Resolve a request's opts to the model, node and deadline it will run with.

  An absent or `"auto"` model is the first configured one. A model that is not
  configured is refused by name, so the caller sees what is allowed instead of a
  silent swap; with nothing configured the source is refused outright.
  """
  @spec resolve(keyword()) ::
          {:ok, %{model: String.t(), node: String.t() | nil, timeout_ms: pos_integer()}}
          | {:error, {:model_not_allowed, String.t(), [String.t()]}}
          | {:error, {:model_not_configured, :local_ollama}}
  def resolve(opts) do
    case models() do
      [] -> {:error, {:model_not_configured, :local_ollama}}
      allowed -> resolve_in(allowed, opts)
    end
  end

  defp resolve_in(allowed, opts) do
    requested =
      case Keyword.get(opts, :model) do
        value when is_binary(value) and value not in ["", "auto"] -> value
        _ -> hd(allowed)["model"]
      end

    case Enum.find(allowed, &(&1["model"] == requested)) do
      nil ->
        {:error, {:model_not_allowed, requested, Enum.map(allowed, & &1["model"])}}

      entry ->
        {:ok, %{model: entry["model"], node: entry["node"], timeout_ms: timeout_ms(opts)}}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp blank_to_nil(_value), do: nil

  @doc "The caller's `timeout_ms`, clamped to the configured ceiling; the configured default when absent."
  @spec timeout_ms(keyword()) :: pos_integer()
  def timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms) do
      value when is_integer(value) and value > 0 -> min(value, number("LOCAL_OLLAMA_MAX_TIMEOUT_MS", @max_timeout_ms))
      _ -> number("LOCAL_OLLAMA_TIMEOUT_MS", @default_timeout_ms)
    end
  end

  @doc "How many jobs may wait behind a running one on a node (a batch is polled, not dropped)."
  @spec max_waiting() :: pos_integer()
  def max_waiting, do: number("LOCAL_OLLAMA_MAX_WAITING", @default_waiting)

  defp number(key, default) do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get(key),
         {value, ""} when value > 0 <- Integer.parse(raw) do
      value
    else
      _ -> default
    end
  end
end
