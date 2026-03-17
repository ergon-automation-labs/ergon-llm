defmodule BotArmyLlm.TokenAccounting do
  @moduledoc """
  Token usage tracking and cost estimation for LLM operations.

  Records all LLM API calls with token counts and estimates costs based
  on provider pricing models.
  """

  require Logger
  alias BotArmyLlm.Schemas.TokenUsage
  import Ecto.Query

  defp repo do
    Application.get_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
  end

  # Pricing per 1M tokens: {input_cost_usd, output_cost_usd}
  @pricing %{
    {"anthropic", ~r/haiku/i} => {0.80, 4.00},
    {"anthropic", ~r/sonnet/i} => {3.00, 15.00},
    {"anthropic", ~r/opus/i} => {15.00, 75.00},
    # All others default to free
  }

  @doc """
  Record a token usage event.

  Args:
    - attrs: %{
        event_id: string (required),
        event_type: string (required),
        source: string (optional),
        provider: string (required),
        model: string (required),
        tokens_input: integer (optional),
        tokens_output: integer (optional),
        latency_ms: integer (optional)
      }

  Returns: {:ok, token_usage} | {:error, reason}
  """
  def record(attrs) when is_map(attrs) do
    cost = estimate_cost(
      attrs["provider"],
      attrs["model"],
      attrs["tokens_input"],
      attrs["tokens_output"]
    )

    record_attrs = Map.put(attrs, "estimated_cost_usd", cost)

    case TokenUsage.changeset(record_attrs) |> repo().insert() do
      {:ok, usage} ->
        Logger.debug("Recorded token usage: #{attrs["event_type"]}")
        {:ok, usage}

      {:error, reason} ->
        Logger.error("Failed to record token usage: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def record(_), do: {:error, :invalid_attributes}

  @doc """
  Estimate cost for tokens.

  Args:
    - provider: string ("anthropic", "ollama", etc.)
    - model: string (model name)
    - tokens_input: integer or nil
    - tokens_output: integer or nil

  Returns: float (estimated cost in USD)
  """
  def estimate_cost(_provider, _model, nil, nil) do
    0.0
  end

  def estimate_cost(provider, model, tokens_in, tokens_out) when is_binary(provider) and is_binary(model) do
    provider = String.downcase(provider)
    {input_rate, output_rate} = find_pricing(provider, model)

    input_cost = if tokens_in, do: (tokens_in * input_rate) / 1_000_000, else: 0.0
    output_cost = if tokens_out, do: (tokens_out * output_rate) / 1_000_000, else: 0.0

    input_cost + output_cost
  end

  def estimate_cost(_, _, _, _), do: 0.0

  @doc """
  Query token usage with aggregations.

  Args:
    - opts: [
        since: DateTime (optional),
        until: DateTime (optional),
        source: string (optional),
        provider: string (optional)
      ]

  Returns: {:ok, summary_map} | {:error, reason}
  """
  def query(opts \\ []) do
    since = Keyword.get(opts, :since)
    until = Keyword.get(opts, :until)
    source = Keyword.get(opts, :source)
    provider = Keyword.get(opts, :provider)

    query_base = from(t in TokenUsage, select: t)

    query_base =
      if since, do: where(query_base, [t], t.inserted_at >= ^since), else: query_base

    query_base =
      if until, do: where(query_base, [t], t.inserted_at <= ^until), else: query_base

    query_base =
      if is_binary(source), do: where(query_base, [t], t.source == ^source), else: query_base

    query_base =
      if is_binary(provider), do: where(query_base, [t], t.provider == ^provider), else: query_base

    try do
      rows = repo().all(query_base)

      # Aggregate results
      summary = %{
        total_calls: length(rows),
        total_tokens_in: Enum.reduce(rows, 0, fn r, acc -> (r.tokens_input || 0) + acc end),
        total_tokens_out: Enum.reduce(rows, 0, fn r, acc -> (r.tokens_output || 0) + acc end),
        total_cost_usd: Enum.reduce(rows, 0.0, fn r, acc -> (r.estimated_cost_usd || 0.0) + acc end),
        by_provider: group_by_provider(rows),
        by_source: group_by_source(rows)
      }

      {:ok, summary}
    rescue
      e ->
        Logger.error("Query failed: #{inspect(e)}")
        {:error, e}
    end
  end

  # Private functions

  defp find_pricing(provider, model) do
    Enum.find_value(@pricing, {0.0, 0.0}, fn {{p, m_regex}, pricing} ->
      if p == provider && Regex.match?(m_regex, model), do: pricing
    end)
  end

  defp group_by_provider(rows) do
    rows
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, group} ->
      {provider, %{
        calls: length(group),
        tokens_in: Enum.reduce(group, 0, fn r, acc -> (r.tokens_input || 0) + acc end),
        tokens_out: Enum.reduce(group, 0, fn r, acc -> (r.tokens_output || 0) + acc end),
        cost_usd: Enum.reduce(group, 0.0, fn r, acc -> (r.estimated_cost_usd || 0.0) + acc end)
      }}
    end)
    |> Map.new()
  end

  defp group_by_source(rows) do
    rows
    |> Enum.group_by(& &1.source)
    |> Enum.filter(fn {s, _} -> is_binary(s) end)
    |> Enum.map(fn {source, group} ->
      {source, %{
        calls: length(group),
        tokens_in: Enum.reduce(group, 0, fn r, acc -> (r.tokens_input || 0) + acc end),
        tokens_out: Enum.reduce(group, 0, fn r, acc -> (r.tokens_output || 0) + acc end),
        cost_usd: Enum.reduce(group, 0.0, fn r, acc -> (r.estimated_cost_usd || 0.0) + acc end)
      }}
    end)
    |> Map.new()
  end
end
