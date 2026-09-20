defmodule BotArmyLlm.Services.NarrativeLlm do
  @moduledoc """
  LLM-based narrative generation for Nova.

  Calls Claude via ClaudePassthroughChain to generate evocative narrative text
  for task/quest contexts. Returns structured JSON with narrative components.
  """

  require Logger
  alias BotArmyLlm.ClaudePassthroughChain
  alias BotArmyLlm.Prompts.NovaTemplate

  @timeout_ms 10_000
  @max_tokens 500

  @doc """
  Generate narrative for a task using Claude.

  Returns `{:ok, narrative_map}` with keys:
  - quest_title
  - scene_flavor
  - beat_next
  - emotional_frame
  """
  def generate_narrative(task_context) do
    prompt = NovaTemplate.build_prompt(task_context)

    request = %{
      "model" => "claude-opus-5",
      "max_tokens" => @max_tokens,
      "system" => NovaTemplate.system_prompt(),
      "messages" => [
        %{
          "role" => "user",
          "content" => prompt
        }
      ]
    }

    Logger.info("Generating narrative for task #{task_context["task_id"]}")

    case ClaudePassthroughChain.run(request) do
      {:ok, response_text} ->
        Logger.debug("Claude response: #{String.slice(response_text, 0..100)}")
        parse_narrative_response(response_text)

      {:error, reason} ->
        Logger.error("Claude generation failed: #{inspect(reason)}")
        {:error, {:llm_failed, reason}}
    end
  end

  # Parse Claude's JSON response
  # Expected format: valid JSON with quest_title, scene_flavor, beat_next, emotional_frame
  defp parse_narrative_response(response_text) do
    # Try to extract JSON from response (Claude may wrap it in markdown code blocks)
    case extract_json(response_text) do
      {:ok, json_text} ->
        case Jason.decode(json_text) do
          {:ok, narrative} -> validate_narrative(narrative)
          {:error, reason} -> {:error, {:decode_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  # Extract JSON from response (handle markdown code blocks)
  defp extract_json(text) do
    text = String.trim(text)

    cond do
      String.starts_with?(text, "```json") ->
        # Extract from markdown code block
        case String.trim_prefix(text, "```json") do
          trimmed ->
            case String.split(trimmed, "```") do
              [json, _rest] -> {:ok, String.trim(json)}
              _ -> {:error, :invalid_code_block}
            end
        end

      String.starts_with?(text, "```") ->
        # Generic code block
        case String.trim_prefix(text, "```") do
          trimmed ->
            case String.split(trimmed, "```") do
              [json, _rest] -> {:ok, String.trim(json)}
              _ -> {:error, :invalid_code_block}
            end
        end

      String.starts_with?(text, "{") ->
        # Raw JSON
        {:ok, text}

      true ->
        # Try to find JSON object in text
        case find_json_in_text(text) do
          {:ok, json} -> {:ok, json}
          :not_found -> {:error, :no_json_found}
        end
    end
  end

  # Find first valid JSON object in text
  defp find_json_in_text(text) do
    case String.split(text, ~r/\{/, parts: 2) do
      [_before, rest] ->
        # Reconstruct JSON by adding back the opening brace
        json_text = "{" <> rest

        # Try to find closing brace
        case find_matching_brace(json_text, 0, 0) do
          {:ok, pos} ->
            {:ok, String.slice(json_text, 0..pos)}

          :not_found ->
            :not_found
        end

      _ ->
        :not_found
    end
  end

  # Find matching closing brace for JSON
  defp find_matching_brace(text, pos, depth) do
    text_len = String.length(text)

    cond do
      pos >= text_len ->
        if depth == 0, do: {:ok, pos - 1}, else: :not_found

      true ->
        char = String.at(text, pos)

        case char do
          "{" -> find_matching_brace(text, pos + 1, depth + 1)
          "}" -> if depth > 1, do: find_matching_brace(text, pos + 1, depth - 1), else: {:ok, pos}
          _ -> find_matching_brace(text, pos + 1, depth)
        end
    end
  end

  # Validate required fields in narrative
  defp validate_narrative(narrative) when is_map(narrative) do
    required_fields = ["quest_title", "scene_flavor", "beat_next", "emotional_frame"]

    case Enum.all?(required_fields, &Map.has_key?(narrative, &1)) do
      true ->
        {:ok, narrative}

      false ->
        missing = Enum.reject(required_fields, &Map.has_key?(narrative, &1))
        {:error, {:missing_fields, missing}}
    end
  end

  defp validate_narrative(_), do: {:error, :not_a_map}
end
