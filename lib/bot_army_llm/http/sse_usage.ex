defmodule BotArmyLlm.Http.SseUsage do
  @moduledoc false

  @doc """
  Extract the last `usage` object Anthropic includes in SSE `data:` lines (streaming).
  Returns `{input_tokens, output_tokens}` or `{nil, nil}` if not found.
  """
  @spec last_usage_from_sse(String.t()) :: {integer() | nil, integer() | nil}
  def last_usage_from_sse(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({nil, nil}, fn line, acc ->
      process_sse_line(line, acc)
    end)
  end

  defp process_sse_line("data: " <> json, acc) do
    case Jason.decode(json) do
      {:ok, decoded} -> extract_usage_from_decoded(decoded, acc)
      _ -> acc
    end
  end

  defp process_sse_line(line, acc) when is_binary(line) do
    case String.trim_leading(line) do
      "data: " <> json -> process_sse_line("data: " <> json, acc)
      _ -> acc
    end
  end

  defp extract_usage_from_decoded(decoded, acc) do
    usage =
      Map.get(decoded, "usage") ||
        get_in(decoded, ["message", "usage"]) ||
        get_in(decoded, ["delta", "usage"])

    case usage do
      %{"input_tokens" => i, "output_tokens" => o} -> {i, o}
      _ -> acc
    end
  end
end
