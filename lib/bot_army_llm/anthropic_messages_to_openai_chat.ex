defmodule BotArmyLlm.AnthropicMessagesToOpenaiChat do
  @moduledoc false
  # Anthropic Messages API request maps → OpenAI-compatible chat/completions body pieces.

  @doc """
  Builds `messages` and optional `tools` for POST /v1/chat/completions.

  Handles Anthropic `tools`, `tool_use` / `tool_result` content blocks, and plain text.
  """
  @spec to_chat_completion_request(map()) ::
          {:ok, %{messages: list(map()), tools: list(map())}} | {:error, atom()}
  def to_chat_completion_request(payload) when is_map(payload) do
    tools = anthropic_tools_to_openai(Map.get(payload, "tools") || [])

    with {:ok, openai_msgs} <-
           convert_messages(Map.get(payload, "messages", []), extract_system_string(payload)) do
      {:ok, %{messages: openai_msgs, tools: tools}}
    end
  end

  defp extract_system_string(payload) do
    case Map.get(payload, "system") do
      nil ->
        nil

      s when is_binary(s) and s != "" ->
        s

      parts when is_list(parts) ->
        parts
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => t} when is_binary(t) -> [t]
          _ -> []
        end)
        |> Enum.join("\n")
        |> case do
          "" -> nil
          t -> t
        end

      _ ->
        nil
    end
  end

  defp convert_messages(messages, system_str) when is_list(messages) do
    prefix =
      if is_binary(system_str) and system_str != "" do
        [%{"role" => "system", "content" => system_str}]
      else
        []
      end

    case do_convert_messages(messages, []) do
      {:ok, rest} -> {:ok, prefix ++ rest}
      {:error, _} = e -> e
    end
  end

  defp do_convert_messages([], acc), do: {:ok, acc}

  defp do_convert_messages([msg | rest], acc) do
    case anthropic_message_to_openai(msg) do
      {:ok, list} when is_list(list) -> do_convert_messages(rest, acc ++ list)
      {:error, _} = e -> e
    end
  end

  defp anthropic_message_to_openai(%{"role" => "user"} = msg) do
    expand_user_message(Map.get(msg, "content"))
  end

  defp anthropic_message_to_openai(%{"role" => "assistant"} = msg) do
    {:ok, [assistant_to_openai(Map.get(msg, "content"))]}
  end

  defp anthropic_message_to_openai(%{"role" => role}) do
    {:error, {:unsupported_message_role, role}}
  end

  defp anthropic_message_to_openai(_), do: {:error, :invalid_message_shape}

  defp expand_user_message(content) when is_binary(content) do
    {:ok, [%{"role" => "user", "content" => content}]}
  end

  defp expand_user_message(parts) when is_list(parts) do
    texts = extract_message_texts(parts)
    tool_results = extract_tool_results(parts)

    if tool_results == [] and texts == [] do
      {:error, :no_user_content}
    else
      base = maybe_user_text([], texts)
      accumulate_tool_results(tool_results, {:ok, base})
    end
  end

  defp expand_user_message(nil), do: {:error, :no_user_content}

  defp extract_message_texts(parts) do
    Enum.flat_map(parts, fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
  end

  defp extract_tool_results(parts) do
    Enum.filter(parts, fn
      %{"type" => "tool_result"} -> true
      _ -> false
    end)
  end

  defp accumulate_tool_results(tool_results, base) do
    Enum.reduce_while(tool_results, base, fn tr, {:ok, acc} ->
      case Map.get(tr, "tool_use_id") do
        id when is_binary(id) and id != "" ->
          row = %{
            "role" => "tool",
            "tool_call_id" => id,
            "content" => tool_result_content_string(tr)
          }

          {:cont, {:ok, acc ++ [row]}}

        _ ->
          {:halt, {:error, :missing_tool_use_id}}
      end
    end)
  end

  defp maybe_user_text(msgs, []), do: msgs

  defp maybe_user_text(msgs, texts) do
    msgs ++ [%{"role" => "user", "content" => Enum.join(texts, "\n")}]
  end

  defp tool_result_content_string(%{"content" => c}) when is_binary(c), do: c

  defp tool_result_content_string(%{"content" => parts}) when is_list(parts) do
    texts =
      Enum.flat_map(parts, fn
        %{"type" => "text", "text" => t} when is_binary(t) -> [t]
        other -> [Jason.encode!(other)]
      end)

    Enum.join(texts, "\n")
  end

  defp tool_result_content_string(_), do: ""

  defp assistant_to_openai(content) when is_binary(content) do
    %{"role" => "assistant", "content" => content}
  end

  defp assistant_to_openai(parts) when is_list(parts) do
    texts = extract_text_parts(parts)
    tool_uses = extract_tool_uses(parts)

    text_content =
      case texts do
        [] -> nil
        _ -> Enum.join(texts, "\n")
      end

    base = %{"role" => "assistant", "content" => text_content}

    if tool_uses == [] do
      base
    else
      calls = Enum.map(tool_uses, &build_tool_call/1)
      Map.put(base, "tool_calls", calls)
    end
  end

  defp assistant_to_openai(nil) do
    %{"role" => "assistant", "content" => nil}
  end

  defp extract_text_parts(parts) do
    Enum.flat_map(parts, fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
  end

  defp extract_tool_uses(parts) do
    Enum.filter(parts, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)
  end

  defp build_tool_call(tu) do
    id = Map.get(tu, "id") || "toolu_unknown"
    name = Map.get(tu, "name") || ""
    input = Map.get(tu, "input") || %{}

    args =
      case input do
        s when is_binary(s) -> s
        _ -> Jason.encode!(input)
      end

    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => args}
    }
  end

  defp anthropic_tools_to_openai([]), do: []

  defp anthropic_tools_to_openai(tools) when is_list(tools) do
    Enum.map(tools, fn t ->
      name = Map.get(t, "name") || ""
      desc = Map.get(t, "description") || ""
      schema = Map.get(t, "input_schema") || %{"type" => "object", "properties" => %{}}

      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => desc,
          "parameters" => schema
        }
      }
    end)
  end
end
