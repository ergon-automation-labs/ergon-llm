defmodule BotArmyLlm.ComplexityScorer do
  @moduledoc """
  Heuristic prompt complexity scorer.

  Classifies prompts as :light, :medium, or :heavy based on
  length and keyword signals — no LLM calls required.

  Complexity drives which provider + model tier is selected:
    :light  → short factual prompts, ministral-3:3b locally
    :medium → explanation/summarization, ministral-3:8b locally
    :heavy  → code generation, multi-step reasoning → cloud providers
  """

  @heavy_keywords ~w[
    implement write code generate create function class module
    algorithm refactor architecture design system explain step-by-step
    compare contrast analyze comprehensive detailed research
    debug trace integration multi-step
  ]

  @light_keywords ~w[
    yes no what who when where brief quick simple short
    define meaning translate single
  ]

  @doc """
  Score a prompt's complexity.
  Returns :light | :medium | :heavy
  """
  @spec score(String.t()) :: :light | :medium | :heavy
  def score(text) when is_binary(text) do
    words = String.split(text)
    word_count = length(words)
    lower = String.downcase(text)

    heavy_hits = Enum.count(@heavy_keywords, &String.contains?(lower, &1))
    light_hits = Enum.count(@light_keywords, &String.contains?(lower, &1))

    score_by_criteria(word_count, heavy_hits, light_hits)
  end

  defp score_by_criteria(word_count, heavy_hits, _light_hits)
       when word_count > 200 or heavy_hits >= 2,
       do: :heavy

  defp score_by_criteria(word_count, heavy_hits, _light_hits)
       when heavy_hits >= 1 and word_count > 10,
       do: :medium

  defp score_by_criteria(word_count, _heavy_hits, _light_hits) when word_count > 100,
    do: :medium

  defp score_by_criteria(word_count, _heavy_hits, light_hits)
       when word_count <= 20 and light_hits >= 1,
       do: :light

  defp score_by_criteria(word_count, _heavy_hits, _light_hits) when word_count <= 50,
    do: :light

  defp score_by_criteria(_word_count, _heavy_hits, _light_hits),
    do: :medium
end
