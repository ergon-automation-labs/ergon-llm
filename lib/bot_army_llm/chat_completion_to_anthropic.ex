defmodule BotArmyLlm.ChatCompletionToAnthropic do
  @moduledoc false

  @doc "Convert OpenAI-style chat/completions JSON body to Anthropic Messages API response JSON string."
  @spec from_chat_completion_body(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def from_chat_completion_body(body, model_default \\ nil) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, response} ->
        {:ok, build_anthropic_response(response, model_default)}

      {:error, _} ->
        {:error, :invalid_chat_completion_json}
    end
  end

  defp build_anthropic_response(response, model_default) do
    model = resolve_model(response, model_default)
    usage = Map.get(response, "usage") || %{}
    message = get_in(response, ["choices", Access.at(0), "message"]) || %{}
    finish = get_in(response, ["choices", Access.at(0), "finish_reason"])

    content = anthropic_content_from_openai_message(message)
    stop_reason = infer_stop_reason(message, finish)

    out = %{
      "id" => response["id"] || "msg-chat-passthrough",
      "type" => "message",
      "role" => "assistant",
      "content" => content,
      "model" => model,
      "stop_reason" => stop_reason,
      "usage" => build_usage(usage)
    }

    Jason.encode!(out)
  end

  defp resolve_model(response, model_default) do
    response["model"] || model_default ||
      System.get_env("OPENROUTER_MODEL_CLAUDE_CODE", "anthropic/claude-3.5-sonnet")
  end

  defp build_usage(usage) do
    %{
      "input_tokens" => Map.get(usage, "prompt_tokens") || 0,
      "output_tokens" => Map.get(usage, "completion_tokens") || 0
    }
  end

  defp anthropic_content_from_openai_message(message) do
    text_blocks = openai_text_blocks(Map.get(message, "content"))
    tool_blocks = openai_tool_blocks(Map.get(message, "tool_calls"))
    blocks = text_blocks ++ tool_blocks

    case blocks do
      [] ->
        [%{"type" => "text", "text" => "No response"}]

      _ ->
        blocks
    end
  end

  defp openai_text_blocks(nil), do: []
  defp openai_text_blocks(""), do: []

  defp openai_text_blocks(s) when is_binary(s) do
    if String.trim(s) == "", do: [], else: [%{"type" => "text", "text" => s}]
  end

  defp openai_text_blocks(_), do: []

  defp openai_tool_blocks(nil), do: []
  defp openai_tool_blocks([]), do: []

  defp openai_tool_blocks(calls) when is_list(calls) do
    Enum.map(calls, fn c ->
      id = Map.get(c, "id") || ""
      fn_map = Map.get(c, "function") || %{}
      name = Map.get(fn_map, "name") || ""
      args_str = Map.get(fn_map, "arguments") || "{}"

      input =
        case Jason.decode(args_str) do
          {:ok, m} when is_map(m) -> m
          _ -> %{"_raw_arguments" => args_str}
        end

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    end)
  end

  defp infer_stop_reason(message, finish) do
    cond do
      has_tool_calls?(message) or finish == "tool_calls" -> "tool_use"
      finish in ["stop", nil, ""] -> "end_turn"
      is_binary(finish) -> finish
      true -> "end_turn"
    end
  end

  defp has_tool_calls?(%{"tool_calls" => t}) when is_list(t), do: t != []
  defp has_tool_calls?(_), do: false
end
