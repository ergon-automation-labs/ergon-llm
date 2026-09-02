defmodule BotArmyLlm.Proxy.Adapter do
  @moduledoc """
  Authoritative domain for translating LLM request and response payloads 
  between different provider formats (e.g., OpenAI $\leftrightarrow$ Anthropic).
  """

  @doc """
  Translate a request body from a source format to the target format.
  """
  def translate_request(body, source \\ "claude_code", target \\ "anthropic") do
    case {source, target} do
      {"claude_code", "anthropic"} -> 
        # Claude Code uses a format very close to Anthropic, 
        # but we can add specific overrides here.
        body
      
      {_, "anthropic"} ->
        # Generic translation to Anthropic Messages API
        translate_to_anthropic(body)

      _ ->
        # Fallback: return as is if no translation is defined
        body
    end
  end

  @doc """
  Translate a response chunk or full response from a provider's format 
  to the target format.
  """
  def translate_response(response, source, target \\ "anthropic") do
    case {source, target} do
      {"ollama", "anthropic"} ->
        translate_ollama_to_anthropic(response)

      {"openai", "anthropic"} ->
        translate_openai_to_anthropic(response)

      _ ->
        response
    end
  end

  # Private Translation Logic

  defp translate_to_anthropic(body) do
    # Implementation for generic translation
    body
  end

  defp translate_ollama_to_anthropic(response) do
    # Translate Ollama's format to Anthropic's SSE format
    # This is where the logic from OllamaAnthropicSseStream will move
    response
  end

  defp translate_openai_to_anthropic(response) do
    # Translate OpenAI's format to Anthropic's SSE format
    # This is where the logic from OpenAIChatAnthropicSseStream will move
    response
  end
end
