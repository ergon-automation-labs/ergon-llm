defmodule BotArmyLlm.AnthropicOllamaAdapter do
  @moduledoc """
  Converts Anthropic Messages API request bodies to Ollama `/api/chat` messages and
  wraps Ollama responses back into Anthropic-shaped JSON for Claude Code clients.

  Used when cloud providers rate-limit (`anthropic_passthrough` → Ollama fallback).

  **Limitations:** requests that require `tools` / `tool_use` are not supported for
  local fallback; callers should detect `{:error, :tools_not_supported_on_ollama_fallback}`.
  """

  @doc """
  Build Ollama chat `messages` list from an Anthropic Messages payload.

  Returns `{:ok, [map]}` or `{:error, reason}`.
  """
  @spec to_ollama_messages(map()) :: {:ok, list(map())} | {:error, atom()}
  def to_ollama_messages(payload) when is_map(payload) do
    case BotArmyLlm.AnthropicMessages.to_simple_chat_messages(payload) do
      {:error, :tools_not_supported_in_simple_chat} ->
        {:error, :tools_not_supported_on_ollama_fallback}

      {:error, :tool_blocks_not_supported_in_simple_chat} ->
        {:error, :tool_blocks_not_supported_on_ollama_fallback}

      {:error, :tool_messages_not_supported_in_simple_chat} ->
        {:error, :tool_messages_not_supported_on_ollama_fallback}

      other ->
        other
    end
  end

  @doc """
  Wrap a successful Ollama `/api/chat` JSON body as Anthropic Messages API response JSON string.
  """
  @spec anthropic_json_from_ollama_chat(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def anthropic_json_from_ollama_chat(ollama_body, model_used)
      when is_binary(ollama_body) and is_binary(model_used) do
    case Jason.decode(ollama_body) do
      {:ok, response} ->
        text =
          get_in(response, ["message", "content"]) ||
            ""

        tin = response["prompt_eval_count"]
        tout = response["eval_count"]

        id = "msg-ollama-" <> (Ecto.UUID.generate() |> String.replace("-", "") |> binary_part(0, 24))

        out = %{
          "id" => id,
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => text}],
          "model" => model_used,
          "stop_reason" => "end_turn",
          "usage" => %{
            "input_tokens" => tin || 0,
            "output_tokens" => tout || 0
          }
        }

        {:ok, Jason.encode!(out)}

      {:error, _} ->
        {:error, :invalid_ollama_json}
    end
  end
end
