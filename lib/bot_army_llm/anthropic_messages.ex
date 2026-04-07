defmodule BotArmyLlm.AnthropicMessages do
  @moduledoc """
  Shared conversion from Anthropic Messages API request maps to simple chat-style
  `messages` lists (`role` + string `content`) for OpenAI-compatible APIs and Ollama.

  Tool use / tool_result are not represented here. For OpenAI-compatible passthrough
  (OpenRouter, Blackbox), see `BotArmyLlm.AnthropicMessagesToOpenaiChat`.
  """

  @doc """
  Returns `{:ok, messages}` suitable for `/v1/chat/completions` or Ollama `/api/chat`.

  Fails with `{:error, :tools_not_supported_in_simple_chat}` when the payload
  includes a non-empty `tools` list or tool blocks in messages.
  """
  @spec to_simple_chat_messages(map()) :: {:ok, list(map())} | {:error, atom()}
  def to_simple_chat_messages(payload) when is_map(payload) do
    tools = Map.get(payload, "tools")

    if is_list(tools) and tools != [] do
      {:error, :tools_not_supported_in_simple_chat}
    else
      do_convert(payload)
    end
  end

  defp do_convert(payload) do
    system_parts = extract_system_parts(payload)

    with {:ok, convo} <- convert_messages(Map.get(payload, "messages", [])) do
      {:ok, system_parts ++ convo}
    end
  end

  defp extract_system_parts(payload) do
    case Map.get(payload, "system") do
      nil ->
        []

      s when is_binary(s) and s != "" ->
        [%{"role" => "system", "content" => s}]

      parts when is_list(parts) ->
        parts
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => t} when is_binary(t) -> [t]
          _ -> []
        end)
        |> Enum.join("\n")
        |> case do
          "" -> []
          text -> [%{"role" => "system", "content" => text}]
        end

      _ ->
        []
    end
  end

  defp convert_messages(messages) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn msg, {:ok, acc} ->
      role = Map.get(msg, "role")

      case to_chat_line(role, Map.get(msg, "content")) do
        {:ok, line} -> {:cont, {:ok, acc ++ [line]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp to_chat_line(role, content) when role in ["user", "assistant"] do
    case normalize_content(content) do
      {:ok, text} -> {:ok, %{"role" => role, "content" => text}}
      err -> err
    end
  end

  defp to_chat_line("tool", _content), do: {:error, :tool_messages_not_supported_in_simple_chat}
  defp to_chat_line(_, _), do: {:error, :unsupported_message_role}

  defp normalize_content(text) when is_binary(text), do: {:ok, text}

  defp normalize_content(parts) when is_list(parts) do
    texts =
      Enum.flat_map(parts, fn
        %{"type" => "text", "text" => t} when is_binary(t) -> [t]
        %{"type" => "tool_use"} -> []
        %{"type" => "tool_result"} -> []
        _ -> []
      end)

    if texts == [] do
      if Enum.any?(parts, &match?(%{"type" => "tool_use"}, &1)) or
           Enum.any?(parts, &match?(%{"type" => "tool_result"}, &1)) do
        {:error, :tool_blocks_not_supported_in_simple_chat}
      else
        {:error, :no_text_content}
      end
    else
      {:ok, Enum.join(texts, "\n")}
    end
  end

  defp normalize_content(nil), do: {:error, :no_text_content}
end
