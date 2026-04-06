defmodule BotArmyLlm.TokenAccounting do
  @moduledoc """
  Token usage tracking and cost estimation for LLM operations.

  ## Cost estimation

  `estimated_cost_usd` on each row is a **rough** internal estimate (not an invoice).

  **Built-in defaults** cover Anthropic name patterns (haiku / sonnet / opus). **Ollama** is treated
  as **$0** (local). **OpenRouter**, **Blackbox**, and anything unknown default to **$0** until you
  add rules.

  **Override** with pillar → `BOT_ARMY_LLM_PRICING_FILE` (JSON file) and/or `BOT_ARMY_LLM_PRICING_JSON`
  (inline JSON). Rules are a JSON **array**; **first matching rule wins**.

  Each rule object:

  - `provider` — `"anthropic"`, `"openrouter"`, `"ollama"`, `"blackbox"`, or `"*"` (match any provider;
    You may also use legacy names `anthropic_ai`, `openrouter_ai`, `blackbox_ai`; they are treated as equivalent.
    useful when the recorded `provider` does not match the real API, but `model` still has the slug).
  - `model_substring` — optional; case-insensitive substring match on the model id.
  - `model_regex` — optional; if set, used instead of `model_substring` (Rust/PCRE-style via Elixir `Regex`).
  - If neither `model_substring` nor `model_regex` is set, the rule matches **any** model for that provider.
  - `input_per_million_usd`, `output_per_million_usd` — USD per 1M tokens (floats).

  Example:

      [
        {"provider": "*", "model_substring": "minimax", "input_per_million_usd": 0.15, "output_per_million_usd": 0.35},
        {"provider": "openrouter", "model_substring": "anthropic/claude", "input_per_million_usd": 3.0, "output_per_million_usd": 15.0}
      ]

  Overlay order: **file rules**, then **JSON env rules**, then **built-in defaults**.

  ## Tenant / user id on `record/1`

  NATS-backed callers should pass `tenant_id` and `user_id` when known.

  When `tenant_id` is missing or blank:

  - If `source` is `"claude_code"` (HTTP Claude Code proxy default), use `BOT_ARMY_LLM_CLAUDE_CODE_TENANT_ID`
    or `BotArmyLlm.WellKnownIds.claude_code_default_tenant/0` (`…0002`).
  - Otherwise use `BOT_ARMY_LLM_DEFAULT_TENANT_ID` or `WellKnownIds.legacy_default_tenant/0` (`…0001`).

  When `user_id` is missing or blank and `source` is `"claude_code"`, use `BOT_ARMY_LLM_CLAUDE_CODE_USER_ID`
  or `WellKnownIds.claude_code_default_user/0` (`…0003`) — synthetic “Claude Code client” actor in that tenant.
  Other sources leave `user_id` unset unless you pass it.

  Custom HTTP tools should set header `x-bot-army-source` to something other than `claude_code` if they should
  not receive the Claude Code identity defaults.
  """

  require Logger
  alias BotArmyLlm.Schemas.TokenUsage
  alias BotArmyLlm.WellKnownIds
  import Ecto.Query

  defp repo do
    Application.get_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
  end

  # Built-in: Anthropic tiers by model name pattern; other providers default to 0 until overridden.
  defp default_pricing_rules do
    [
      %{provider: "anthropic", match: {:regex, ~r/haiku/i}, rates: {0.80, 4.00}},
      %{provider: "anthropic", match: {:regex, ~r/sonnet/i}, rates: {3.00, 15.00}},
      %{provider: "anthropic", match: {:regex, ~r/opus/i}, rates: {15.00, 75.00}},
      %{provider: "ollama", match: :any, rates: {0.0, 0.0}},
      %{provider: "openrouter", match: :any, rates: {0.0, 0.0}},
      %{provider: "blackbox", match: :any, rates: {0.0, 0.0}}
    ]
  end

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
        latency_ms: integer (optional),
        tenant_id: string UUID (optional — see module doc),
        user_id: string UUID (optional — see module doc)
      }

  Returns: {:ok, token_usage} | {:error, reason}
  """
  def record(attrs) when is_map(attrs) do
    attrs = apply_identity_defaults(attrs)

    cost = estimate_cost(
      attrs["provider"],
      attrs["model"],
      attrs["tokens_input"],
      attrs["tokens_output"]
    )

    record_attrs = Map.put(attrs, "estimated_cost_usd", cost)
    changeset = TokenUsage.changeset(record_attrs)

    try do
      case repo().insert(changeset) do
        {:ok, usage} ->
          Logger.debug("Recorded token usage: #{record_attrs["event_type"]}")
          {:ok, usage}

        {:error, reason} ->
          Logger.error("Failed to record token usage: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e in Postgrex.Error ->
        Logger.error("Failed to record token usage (database): #{Exception.message(e)}")
        {:error, e}

      e in DBConnection.ConnectionError ->
        Logger.error("Failed to record token usage (connection): #{Exception.message(e)}")
        {:error, e}
    end
  end

  def record(_), do: {:error, :invalid_attributes}

  defp apply_identity_defaults(attrs) do
    source = source_label(attrs)
    attrs |> put_default_tenant_id(source) |> put_default_user_id(source)
  end

  defp source_label(attrs) do
    case Map.get(attrs, "source") || Map.get(attrs, :source) do
      s when is_binary(s) -> String.trim(s)
      _ -> ""
    end
  end

  defp put_default_tenant_id(attrs, source) do
    tid = Map.get(attrs, "tenant_id") || Map.get(attrs, :tenant_id)

    if tid in [nil, ""] do
      tenant =
        if source == "claude_code" do
          case System.get_env("BOT_ARMY_LLM_CLAUDE_CODE_TENANT_ID") do
            v when is_binary(v) and v != "" -> v
            _ -> WellKnownIds.claude_code_default_tenant()
          end
        else
          case System.get_env("BOT_ARMY_LLM_DEFAULT_TENANT_ID") do
            v when is_binary(v) and v != "" -> v
            _ -> WellKnownIds.legacy_default_tenant()
          end
        end

      attrs
      |> Map.delete(:tenant_id)
      |> Map.put("tenant_id", tenant)
    else
      attrs
    end
  end

  defp put_default_user_id(attrs, source) do
    uid = Map.get(attrs, "user_id") || Map.get(attrs, :user_id)

    if uid in [nil, ""] and source == "claude_code" do
      user =
        case System.get_env("BOT_ARMY_LLM_CLAUDE_CODE_USER_ID") do
          v when is_binary(v) and v != "" -> v
          _ -> WellKnownIds.claude_code_default_user()
        end

      attrs
      |> Map.delete(:user_id)
      |> Map.put("user_id", user)
    else
      attrs
    end
  end

  @doc """
  Estimate cost for tokens.

  Args:
    - provider: string ("anthropic", "openrouter", "ollama", …)
    - model: string (model id as recorded)
    - tokens_input: integer or nil
    - tokens_output: integer or nil

  Returns: float (estimated cost in USD)
  """
  def estimate_cost(_provider, _model, nil, nil) do
    0.0
  end

  def estimate_cost(provider, model, tokens_in, tokens_out) when is_binary(provider) and is_binary(model) do
    provider_lc = String.downcase(provider)
    {input_rate, output_rate} = find_pricing(provider_lc, model)

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

  defp find_pricing(provider_lc, model) do
    model_str = model || ""
    provider_norm = normalize_pricing_provider_name(provider_lc)

    rules = pricing_overlay_rules() ++ default_pricing_rules()

    case Enum.find(rules, &rule_matches?(&1, provider_norm, model_str)) do
      %{rates: {i, o}} -> {i, o}
      _ -> {0.0, 0.0}
    end
  end

  defp pricing_overlay_rules do
    from_file = read_pricing_file_rules()
    from_json = read_pricing_json_env_rules()
    from_file ++ from_json
  end

  defp read_pricing_file_rules do
    case System.get_env("BOT_ARMY_LLM_PRICING_FILE") do
      nil ->
        []

      "" ->
        []

      path ->
        case File.read(path) do
          {:ok, body} ->
            decode_rules_list(body, "file #{path}")

          {:error, reason} ->
            Logger.warning("BOT_ARMY_LLM_PRICING_FILE read failed: #{path} (#{inspect(reason)})")
            []
        end
    end
  end

  defp read_pricing_json_env_rules do
    case System.get_env("BOT_ARMY_LLM_PRICING_JSON") do
      nil ->
        []

      "" ->
        []

      json ->
        decode_rules_list(json, "BOT_ARMY_LLM_PRICING_JSON")
    end
  end

  defp decode_rules_list(body, source_tag) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, fn item ->
          case parse_overlay_rule(item) do
            {:ok, rule} -> [rule]
            {:error, reason} ->
              Logger.warning("Ignoring pricing rule from #{source_tag}: #{inspect(reason)} item=#{inspect(item, limit: 100)}")
              []
          end
        end)

      {:ok, other} ->
        Logger.warning("Pricing overlay from #{source_tag} must be a JSON array, got: #{inspect(other)}")
        []

      {:error, e} ->
        Logger.warning("Invalid JSON in #{source_tag}: #{inspect(e)}")
        []
    end
  end

  defp parse_overlay_rule(%{} = m) do
    with {:ok, in_r} <- parse_float(Map.get(m, "input_per_million_usd")),
         {:ok, out_r} <- parse_float(Map.get(m, "output_per_million_usd")),
         {:ok, match} <- match_spec_from_map(m) do
      prov =
        case Map.get(m, "provider") do
          p when is_binary(p) -> normalize_pricing_provider_name(String.trim(p))
          _ -> "*"
        end

      prov = if prov == "", do: "*", else: prov
      {:ok, %{provider: prov, match: match, rates: {in_r, out_r}}}
    end
  end

  defp parse_overlay_rule(_), do: {:error, :not_a_map}

  defp match_spec_from_map(m) do
    cond do
      is_binary(Map.get(m, "model_regex")) and String.trim(Map.get(m, "model_regex")) != "" ->
        case Regex.compile(String.trim(Map.get(m, "model_regex"))) do
          {:ok, re} -> {:ok, {:regex, re}}
          {:error, e} -> {:error, {:bad_regex, e}}
        end

      is_binary(Map.get(m, "model_substring")) and String.trim(Map.get(m, "model_substring")) != "" ->
        {:ok, {:contains, String.downcase(String.trim(Map.get(m, "model_substring")))}}

      true ->
        {:ok, :any}
    end
  end

  defp parse_float(v) when is_number(v), do: {:ok, v * 1.0}

  defp parse_float(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {f, _} -> {:ok, f}
      :error -> {:error, :not_a_float}
    end
  end

  defp parse_float(_), do: {:error, :not_a_float}

  defp rule_matches?(%{provider: "*", match: match, rates: _rates}, _provider_lc, model_str) do
    model_matches?(match, model_str)
  end

  defp rule_matches?(%{provider: p, match: match, rates: _rates}, provider_lc, model_str)
       when is_binary(p) do
    normalize_pricing_provider_name(p) == provider_lc and model_matches?(match, model_str)
  end

  # Pillar used anthropic_ai / openrouter_ai / blackbox_ai; chain + DB use short names — treat as one.
  defp normalize_pricing_provider_name(p) when is_binary(p) do
    case String.downcase(String.trim(p)) do
      "anthropic_ai" -> "anthropic"
      "openrouter_ai" -> "openrouter"
      "blackbox_ai" -> "blackbox"
      other -> other
    end
  end

  defp model_matches?(:any, _model_str), do: true

  defp model_matches?({:contains, sub}, model_str) do
    String.contains?(String.downcase(model_str), sub)
  end

  defp model_matches?({:regex, %Regex{} = re}, model_str) do
    Regex.match?(re, model_str)
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
