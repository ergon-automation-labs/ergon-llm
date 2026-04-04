defmodule BotArmyLlm.ChatCompletionToAnthropic do
  @moduledoc false

  @doc "Convert OpenAI-style chat/completions JSON body to Anthropic Messages API response JSON string."
  @spec from_chat_completion_body(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def from_chat_completion_body(body, model_default \\ nil) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, response} ->
        model =
          response["model"] || model_default ||
            System.get_env("OPENROUTER_MODEL_CLAUDE_CODE", "anthropic/claude-3.5-sonnet")

        usage = Map.get(response, "usage") || %{}

        out = %{
          "id" => response["id"] || "msg-chat-passthrough",
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "text",
              "text" =>
                get_in(response, ["choices", Access.at(0), "message", "content"]) ||
                  "No response"
            }
          ],
          "model" => model,
          "stop_reason" => "end_turn",
          "usage" => %{
            "input_tokens" => Map.get(usage, "prompt_tokens") || 0,
            "output_tokens" => Map.get(usage, "completion_tokens") || 0
          }
        }

        {:ok, Jason.encode!(out)}

      {:error, _} ->
        {:error, :invalid_chat_completion_json}
    end
  end
end
