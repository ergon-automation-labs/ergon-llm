defmodule BotArmyLlm.LlmClient do
  @moduledoc """
  Multi-provider LLM client with complexity-aware routing.

  ## Routing flow

  1. Score prompt complexity: :light | :medium | :heavy (heuristic, no LLM call)
  2. Select provider chain based on complexity:
     - :light/:medium  → local Ollama → blackbox.ai → openrouter → anthropic
     - :heavy          → blackbox.ai → openrouter → anthropic (skip local)
  3. Local Ollama routing uses OllamaHealthChecker to pick the lowest-latency
     healthy node (Air now, Mini when it comes online).
  4. Fall through the chain on any failure.

  ## Model tiers (configured via env vars, set by Salt from pillar)

  Each provider has light/medium/heavy model variants:
    OLLAMA_MODEL_LIGHT / OLLAMA_MODEL_MEDIUM
    BLACKBOX_MODEL_LIGHT / BLACKBOX_MODEL_MEDIUM / BLACKBOX_MODEL_HEAVY
    OPENROUTER_MODEL_LIGHT / OPENROUTER_MODEL_MEDIUM / OPENROUTER_MODEL_HEAVY
    ANTHROPIC_MODEL_LIGHT / ANTHROPIC_MODEL_MEDIUM / ANTHROPIC_MODEL_HEAVY

  ## Return value

  {:ok, %{completion: str, model_used: str, provider: atom,
          tokens_input: int, tokens_output: int, latency_ms: int}}
  | {:error, reason}
  """

  require Logger

  alias BotArmyLlm.{
    ComplexityScorer,
    EmbeddingConfig,
    HttpFallback,
    OllamaHealthChecker,
    OllamaWireFormat,
    SafetyClassifier
  }

  # Get health checker module from app config (for testing) or use default
  defp health_checker_module do
    Application.get_env(:bot_army_llm, :ollama_health_checker, OllamaHealthChecker)
  end

  defp anthropic_url,
    do: System.get_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com/v1/messages")

  defp anthropic_fallback_url,
    do: System.get_env("ANTHROPIC_FALLBACK_URL", "https://api.anthropic.com/v1/messages")

  defp openrouter_fallback_url,
    do: System.get_env("OPENROUTER_FALLBACK_URL", "https://openrouter.ai/api/v1/chat/completions")

  @doc """
  Complete a prompt using the best available provider.

  Checks payload for sensitive data (API keys, credentials, PII, etc.)
  and routes to local-only providers if sensitive content detected.

  Options:
    - `model`: Override model selection ("auto" uses complexity routing)
    - `temperature`: Generation temperature (default: 0.7)
    - `max_tokens`: Max response tokens (default: 1000)
  """
  def complete(text, opts \\ []) when is_binary(text) do
    text = BotArmyLlm.ReasoningScaffold.wrap(text, opts)
    start_time = System.monotonic_time(:millisecond)
    complexity = ComplexityScorer.score(text)
    allow_cloud_when_sensitive = Keyword.get(opts, :allow_cloud_when_sensitive, false)

    # Check for sensitive data before routing
    providers =
      if SafetyClassifier.safe_for_cloud?(text) or allow_cloud_when_sensitive do
        provider_chain(complexity)
      else
        SafetyClassifier.log_decision(:contains_sensitive, "routing to local-only providers")
        # Local only
        [:ollama]
      end
      |> drop_failed_providers(opts)

    Logger.debug(
      "LLM routing: complexity=#{complexity}, chain=#{inspect(providers)}, safety_checked=true"
    )

    case try_providers(providers, text, complexity, opts) do
      {:ok, result} ->
        latency = System.monotonic_time(:millisecond) - start_time
        {:ok, Map.put(result, :latency_ms, latency)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate embeddings for a text string using OpenAI-compatible or Ollama API.

  When `model` is `nil`, Ollama uses `EmbeddingConfig.default_model/0` and OpenRouter uses
  `EmbeddingConfig.openrouter_embed_default_model/0` (can differ). When `model` is a binary, both
  providers receive that id.

  Checks payload for sensitive data (API keys, credentials, PII, etc.)
  and routes to local-only providers if sensitive content detected.

  Returns: `{:ok, %{embedding: [float], model_used: str, latency_ms: int}}`
  """
  def embed(text, model \\ nil) when is_binary(text) and (is_binary(model) or is_nil(model)) do
    {ollama_model, openrouter_model} =
      case model do
        nil ->
          {EmbeddingConfig.default_model(), EmbeddingConfig.openrouter_embed_default_model()}

        m when is_binary(m) ->
          {m, m}
      end

    start_time = System.monotonic_time(:millisecond)

    # Check for sensitive data before routing
    chain = resolved_embed_provider_chain()

    providers =
      if SafetyClassifier.safe_for_cloud?(text) do
        chain
      else
        SafetyClassifier.log_decision(
          :contains_sensitive,
          "routing embed to local-only providers"
        )

        # Local only - filter to just ollama_embed
        Enum.filter(chain, fn p -> p == :ollama_embed end)
      end

    Logger.debug("Embed routing: providers=#{inspect(providers)}, safety_checked=true")

    case try_embed_providers(providers, text, ollama_model, openrouter_model) do
      {:ok, result} ->
        latency = System.monotonic_time(:millisecond) - start_time
        {:ok, Map.put(result, :latency_ms, latency)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Complete using a pre-built messages list (for multi-turn conversations).

  Takes a messages list with format: [%{"role" => "user|assistant", "content" => text}, ...]
  Checks all message content for sensitive data and routes to local-only if found.

  Options:
    - `model`: Override model selection ("auto" uses complexity routing)
    - `temperature`: Generation temperature (default: 0.7)
    - `max_tokens`: Max response tokens (default: 1000)
  """
  def complete_messages(messages, opts \\ []) when is_list(messages) do
    messages = BotArmyLlm.ReasoningScaffold.wrap_messages(messages, opts)
    start_time = System.monotonic_time(:millisecond)

    # Score based on the last user message if available
    complexity =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1["role"] == "user"))
      |> case do
        %{"content" => content} when is_binary(content) -> ComplexityScorer.score(content)
        _ -> :medium
      end

    # Check all messages for sensitive data
    messages_text = Enum.map_join(messages, " ", & &1["content"])

    providers =
      if SafetyClassifier.safe_for_cloud?(messages_text) do
        provider_chain(complexity)
      else
        SafetyClassifier.log_decision(
          :contains_sensitive,
          "routing to local-only providers (multi-turn)"
        )

        # Local only
        [:ollama]
      end
      |> drop_failed_providers(opts)

    Logger.debug(
      "LLM routing (messages): complexity=#{complexity}, chain=#{inspect(providers)}, safety_checked=true"
    )

    case try_providers_messages(providers, messages, complexity, opts) do
      {:ok, result} ->
        latency = System.monotonic_time(:millisecond) - start_time
        {:ok, Map.put(result, :latency_ms, latency)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Analyze an image using a vision model.

  Takes either `image_data` (base64) or `image_url` or both.
  Checks prompt text for sensitive data and routes to local-only if found.

  Options:
    - `temperature`: Generation temperature (default: 0.7)
    - `max_tokens`: Max response tokens (default: 1000)

  Returns: `{:ok, %{completion: analysis, model_used: model, tokens_input: int, tokens_output: int, latency_ms: int}}`
  """
  def complete_vision(image_data_base64, image_url, prompt_text, opts \\ [])
      when (is_binary(image_data_base64) or is_nil(image_data_base64)) and
             (is_binary(image_url) or is_nil(image_url)) and
             is_binary(prompt_text) do
    if is_nil(image_data_base64) and is_nil(image_url) do
      {:error, :no_image_provided}
    else
      run_vision_analysis(image_data_base64, image_url, prompt_text, opts)
    end
  end

  defp run_vision_analysis(image_data_base64, image_url, prompt_text, opts) do
    start_time = System.monotonic_time(:millisecond)
    providers = select_vision_providers(prompt_text)
    Logger.debug("LLM vision routing: chain=#{inspect(providers)}, safety_checked=true")

    case try_vision_providers(providers, image_data_base64, image_url, prompt_text, opts) do
      {:ok, result} ->
        latency = System.monotonic_time(:millisecond) - start_time
        {:ok, Map.put(result, :latency_ms, latency)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_vision_providers(prompt_text) do
    if SafetyClassifier.safe_for_cloud?(prompt_text) do
      [:ollama_vision, :anthropic_vision, :openrouter_vision]
    else
      SafetyClassifier.log_decision(
        :contains_sensitive,
        "routing vision to local-only providers"
      )

      [:ollama_vision]
    end
  end

  @doc """
  Direct pass-through to Anthropic API for Claude Code requests.

  Accepts the full Anthropic Messages API payload (messages, tools, system, etc.)
  and forwards it directly to Anthropic, preserving all features like tools and
  system prompts. No complexity scoring — this is for Claude Code itself.

  Provider order and fallbacks are configured via `BOT_ARMY_LLM_CLAUDE_CHAIN` and implemented in
  `BotArmyLlm.ClaudePassthroughChain` (see that module).

  Returns: {:ok, response_body_json_string} | {:error, reason}
  """
  def anthropic_passthrough(payload) when is_map(payload) do
    BotArmyLlm.ClaudePassthroughChain.run(payload)
  end

  # Provider chain selection

  @doc false
  @spec resolved_provider_chain() :: list(atom())
  def resolved_provider_chain do
    case Application.get_env(:bot_army_llm, :provider_chain) do
      list when is_list(list) ->
        list

      nil ->
        case System.get_env("BOT_ARMY_LLM_PROVIDER_CHAIN") do
          nil -> [:ollama, :blackbox, :openrouter, :anthropic]
          env_str -> parse_provider_chain_string(env_str)
        end
    end
  end

  defp parse_provider_chain_string(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.map(fn
      "ollama" -> :ollama
      "blackbox" -> :blackbox
      "openrouter" -> :openrouter
      "anthropic" -> :anthropic
      unknown -> raise ArgumentError, "Unknown provider: #{unknown}"
    end)
  end

  defp provider_chain(:heavy) do
    # Check if custom chain is configured, otherwise use default
    chain = resolved_provider_chain()
    if :ollama in chain, do: chain ++ [:ollama], else: chain
  end

  defp provider_chain(_complexity) do
    # Check if custom chain is configured
    chain = resolved_provider_chain()

    if health_checker_module().load_acceptable?() do
      # Ensure ollama is first if in chain, otherwise use configured order
      if :ollama in chain do
        [:ollama | List.delete(chain, :ollama)]
      else
        chain
      end
    else
      Logger.info("LLM: Local nodes under load — routing to cloud providers")
      chain
    end
  end

  @doc false
  @spec resolved_embed_provider_chain() :: list(atom())
  def resolved_embed_provider_chain do
    case Application.get_env(:bot_army_llm, :embed_provider_chain) do
      list when is_list(list) ->
        list

      nil ->
        case System.get_env("BOT_ARMY_LLM_EMBED_PROVIDER_CHAIN") do
          nil -> [:ollama_embed, :openrouter_embed]
          env_str -> parse_embed_provider_chain_string(env_str)
        end
    end
  end

  defp parse_embed_provider_chain_string(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.map(fn
      "ollama" -> :ollama_embed
      "openrouter" -> :openrouter_embed
      unknown -> raise ArgumentError, "Unknown embed provider: #{unknown}"
    end)
  end

  defp drop_failed_providers(providers, opts) when is_list(providers) do
    skip = failed_provider_skip_set(opts)

    if MapSet.size(skip) == 0 do
      providers
    else
      Enum.reject(providers, fn provider ->
        MapSet.member?(skip, provider) or MapSet.member?(skip, Atom.to_string(provider))
      end)
    end
  end

  defp failed_provider_skip_set(opts) do
    (normalize_provider_list(Keyword.get(opts, :failed_providers, [])) ++
       normalize_provider_list(Keyword.get(opts, :skip_providers, [])) ++
       normalize_provider_list(List.wrap(Keyword.get(opts, :provider_failed))))
    |> Enum.flat_map(&provider_token_variants/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_provider_list(values) when is_list(values) do
    Enum.flat_map(values, &normalize_provider_list/1)
  end

  defp normalize_provider_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_provider_list(value) when is_atom(value) do
    [Atom.to_string(value)]
  end

  defp normalize_provider_list(_), do: []

  defp provider_token_variants(token) when is_binary(token) do
    down = String.downcase(String.trim(token))

    cond do
      down == "" ->
        []

      down in ["local_fallback", "deterministic_fallback"] ->
        ["local_fallback", "deterministic_fallback"]

      String.starts_with?(down, ":") ->
        [down, String.trim_leading(down, ":")]

      true ->
        [down, ":" <> down]
    end
  end

  # Chain traversal

  defp try_providers([], _text, _complexity, _opts) do
    {:error, :no_providers_available}
  end

  defp try_providers([provider | rest], text, complexity, opts) do
    case BotArmyLlm.CircuitBreaker.allow?(provider) do
      :ok ->
        case call_provider(provider, text, complexity, opts) do
          {:ok, result} ->
            BotArmyLlm.CircuitBreaker.record_success(provider)
            Logger.info("LLM provider #{provider} succeeded, model=#{result.model_used}")
            {:ok, Map.put(result, :provider, provider)}

          {:error, :rate_limited} ->
            BotArmyLlm.CircuitBreaker.record_failure(provider, :rate_limited)
            Logger.warning("Provider #{provider} rate limited, trying next")
            try_providers(rest, text, complexity, opts)

          {:error, reason} ->
            BotArmyLlm.CircuitBreaker.record_failure(provider, reason)
            Logger.warning("Provider #{provider} failed: #{inspect(reason)}, trying next")
            try_providers(rest, text, complexity, opts)
        end

      {:open, retry_after} ->
        Logger.warning("Circuit open for #{provider}, retry after #{retry_after}ms")
        try_providers(rest, text, complexity, opts)
    end
  end

  # Provider implementations

  defp call_provider(:ollama, text, complexity, opts) do
    # Use model from opts if provided, otherwise let health checker decide
    requested_model = Keyword.get(opts, :model)

    case health_checker_module().best_ollama_node(complexity) do
      {:ok, {url, default_model}} ->
        model =
          if is_binary(requested_model) and requested_model != "auto",
            do: requested_model,
            else: default_model

        case ollama_call(url, model, text) do
          {:ok, completion} -> {:ok, %{completion: completion, model_used: model}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp call_provider(:blackbox, text, complexity, opts) do
    api_key = System.get_env("BLACKBOX_API_KEY")
    base_url = System.get_env("BLACKBOX_BASE_URL", "https://api.blackbox.ai/api/chat")
    model = cloud_model(:blackbox, complexity)

    case {api_key, model} do
      {nil, _} -> {:error, :provider_not_configured}
      {_, ""} -> {:error, :model_not_configured}
      {key, m} -> openai_compatible_call(base_url, key, text, m, opts, [])
    end
  end

  defp call_provider(:openrouter, text, complexity, opts) do
    api_key = System.get_env("OPENROUTER_API_KEY")

    base_url =
      System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1/chat/completions")

    model = cloud_model(:openrouter, complexity)

    # OpenRouter requires HTTP-Referer header
    extra_headers = [{"HTTP-Referer", "https://github.com/ergon-automation-labs"}]

    case {api_key, model} do
      {nil, _} ->
        {:error, :provider_not_configured}

      {_, ""} ->
        {:error, :model_not_configured}

      {key, m} ->
        openai_compatible_call(
          base_url,
          key,
          text,
          m,
          opts,
          extra_headers,
          openrouter_fallback_url()
        )
    end
  end

  defp call_provider(:anthropic, text, complexity, opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY")
    model = cloud_model(:anthropic, complexity)

    case {api_key, model} do
      {nil, _} -> {:error, :provider_not_configured}
      {_, ""} -> {:error, :model_not_configured}
      {key, m} -> anthropic_call(key, text, m, opts)
    end
  end

  # Model selection per provider + complexity

  defp cloud_model(:blackbox, :light),
    do: System.get_env("BLACKBOX_MODEL_LIGHT", "qwen/qwen3-14b:free")

  defp cloud_model(:blackbox, :medium),
    do: System.get_env("BLACKBOX_MODEL_MEDIUM", "qwen/qwen3-32b:free")

  defp cloud_model(:blackbox, :heavy),
    do: System.get_env("BLACKBOX_MODEL_HEAVY", "qwen/qwen3-235b-a22b:free")

  defp cloud_model(:openrouter, :light),
    do: System.get_env("OPENROUTER_MODEL_LIGHT", "qwen/qwen3-4b:free")

  defp cloud_model(:openrouter, :medium),
    do: System.get_env("OPENROUTER_MODEL_MEDIUM", "qwen/qwen3-32b:free")

  defp cloud_model(:openrouter, :heavy),
    do: System.get_env("OPENROUTER_MODEL_HEAVY", "qwen/qwen3-235b-a22b-2507")

  defp cloud_model(:anthropic, :light),
    do: System.get_env("ANTHROPIC_MODEL_LIGHT", "claude-3-5-haiku-latest")

  defp cloud_model(:anthropic, :medium),
    do: System.get_env("ANTHROPIC_MODEL_MEDIUM", "claude-3-5-sonnet-latest")

  defp cloud_model(:anthropic, :heavy),
    do: System.get_env("ANTHROPIC_MODEL_HEAVY", "claude-3-5-sonnet-latest")

  # HTTP implementations

  defp ollama_timeout_ms do
    parse_timeout_ms(System.get_env("OLLAMA_TIMEOUT_MS"), 15_000)
  end

  defp parse_timeout_ms(nil, default), do: default

  defp parse_timeout_ms(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp ollama_call(url, model, text) do
    if OllamaWireFormat.wire_format() == :openai do
      ollama_call_openai(url, model, text)
    else
      ollama_call_native(url, model, text)
    end
  end

  defp ollama_call_native(url, model, text) do
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = ollama_timeout_ms()

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => text}],
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: timeout_ms, timeout: timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             completion when is_binary(completion) <- get_in(response, ["message", "content"]) do
          {:ok, completion}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp ollama_call_openai(url, model, text) do
    endpoint = "#{OllamaWireFormat.chat_url()}/v1/chat/completions"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = ollama_timeout_ms()

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => text}],
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: timeout_ms, timeout: timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             completion when is_binary(completion) <-
               get_in(response, ["choices", Access.at(0), "message", "content"]) do
          {:ok, completion}
        else
          _ -> {:error, :invalid_response_format}
        end

      result ->
        if HttpFallback.down?(result) do
          Logger.warning("[headroom-down] ollama chat fell back to native direct")
          ollama_call_native(url, model, text)
        else
          case result do
            {:ok, %HTTPoison.Response{status_code: status}} -> {:error, {:http_error, status}}
            {:error, reason} -> {:error, {:connection_error, reason}}
          end
        end
    end
  rescue
    _ -> {:error, :request_failed}
  end

  # OpenAI-compatible API (blackbox.ai, openrouter)
  defp openai_compatible_call(
         endpoint,
         api_key,
         text,
         model,
         opts,
         extra_headers,
         fallback_url \\ nil
       ) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    headers =
      [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{api_key}"}
      ] ++ extra_headers

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => text}],
        "temperature" => temperature,
        "max_tokens" => max_tokens
      })

    case HttpFallback.post_with_fallback(endpoint, fallback_url, payload, headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             completion when is_binary(completion) <-
               get_in(response, ["choices", Access.at(0), "message", "content"]) do
          {:ok,
           %{
             completion: completion,
             model_used: model,
             tokens_input: get_in(response, ["usage", "prompt_tokens"]) || 0,
             tokens_output: get_in(response, ["usage", "completion_tokens"]) || 0
           }}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.warning("OpenAI-compatible call failed: status=#{status}, body=#{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp anthropic_call(api_key, text, model, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    payload =
      Jason.encode!(%{
        "model" => model,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "messages" => [%{"role" => "user", "content" => text}]
      })

    case HttpFallback.post_with_fallback(
           anthropic_url(),
           anthropic_fallback_url(),
           payload,
           headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             text_block when is_binary(text_block) <-
               response
               |> Map.get("content", [])
               |> Enum.find(&(&1["type"] == "text"))
               |> then(& &1["text"]) do
          {:ok,
           %{
             completion: text_block,
             model_used: model,
             tokens_input: get_in(response, ["usage", "input_tokens"]) || 0,
             tokens_output: get_in(response, ["usage", "output_tokens"]) || 0
           }}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  # Messages-based provider chain traversal (for conversations)

  defp try_providers_messages([], _messages, _complexity, _opts) do
    {:error, :no_providers_available}
  end

  defp try_providers_messages([provider | rest], messages, complexity, opts) do
    case BotArmyLlm.CircuitBreaker.allow?(provider) do
      :ok ->
        case call_provider_messages(provider, messages, complexity, opts) do
          {:ok, result} ->
            BotArmyLlm.CircuitBreaker.record_success(provider)

            Logger.info(
              "LLM provider #{provider} succeeded (messages), model=#{result.model_used}"
            )

            {:ok, Map.put(result, :provider, provider)}

          {:error, :rate_limited} ->
            BotArmyLlm.CircuitBreaker.record_failure(provider, :rate_limited)
            Logger.warning("Provider #{provider} rate limited (messages), trying next")
            try_providers_messages(rest, messages, complexity, opts)

          {:error, reason} ->
            BotArmyLlm.CircuitBreaker.record_failure(provider, reason)

            Logger.warning(
              "Provider #{provider} failed (messages): #{inspect(reason)}, trying next"
            )

            try_providers_messages(rest, messages, complexity, opts)
        end

      {:open, retry_after} ->
        Logger.warning("Circuit open for #{provider} (messages), retry after #{retry_after}ms")
        try_providers_messages(rest, messages, complexity, opts)
    end
  end

  defp call_provider_messages(:ollama, messages, _complexity, _opts) do
    case health_checker_module().best_ollama_node(:medium) do
      {:ok, {url, model}} ->
        case ollama_call_messages(url, model, messages) do
          {:ok, completion} -> {:ok, %{completion: completion, model_used: model}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp call_provider_messages(:blackbox, messages, complexity, opts) do
    api_key = System.get_env("BLACKBOX_API_KEY")
    base_url = System.get_env("BLACKBOX_BASE_URL", "https://api.blackbox.ai/api/chat")
    model = cloud_model(:blackbox, complexity)

    case {api_key, model} do
      {nil, _} -> {:error, :provider_not_configured}
      {_, ""} -> {:error, :model_not_configured}
      {key, m} -> openai_compatible_call_messages(base_url, key, messages, m, opts, [])
    end
  end

  defp call_provider_messages(:openrouter, messages, complexity, opts) do
    api_key = System.get_env("OPENROUTER_API_KEY")

    base_url =
      System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1/chat/completions")

    model = cloud_model(:openrouter, complexity)
    extra_headers = [{"HTTP-Referer", "https://github.com/ergon-automation-labs"}]

    case {api_key, model} do
      {nil, _} ->
        {:error, :provider_not_configured}

      {_, ""} ->
        {:error, :model_not_configured}

      {key, m} ->
        openai_compatible_call_messages(
          base_url,
          key,
          messages,
          m,
          opts,
          extra_headers,
          openrouter_fallback_url()
        )
    end
  end

  defp call_provider_messages(:anthropic, messages, complexity, opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY")
    model = cloud_model(:anthropic, complexity)

    case {api_key, model} do
      {nil, _} -> {:error, :provider_not_configured}
      {_, ""} -> {:error, :model_not_configured}
      {key, m} -> anthropic_call_messages(key, messages, m, opts)
    end
  end

  defp call_provider_messages(_, _messages, _complexity, _opts) do
    {:error, :unknown_provider}
  end

  defp ollama_call_messages(url, model, messages) do
    if OllamaWireFormat.wire_format() == :openai do
      ollama_call_messages_openai(url, model, messages)
    else
      ollama_call_messages_native(url, model, messages)
    end
  end

  defp ollama_call_messages_native(url, model, messages) do
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = ollama_timeout_ms()

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => messages,
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: timeout_ms, timeout: timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             completion when is_binary(completion) <- get_in(response, ["message", "content"]) do
          {:ok, completion}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp ollama_call_messages_openai(url, model, messages) do
    endpoint = "#{OllamaWireFormat.chat_url()}/v1/chat/completions"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = ollama_timeout_ms()

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => messages,
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: timeout_ms, timeout: timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             completion when is_binary(completion) <-
               get_in(response, ["choices", Access.at(0), "message", "content"]) do
          {:ok, completion}
        else
          _ -> {:error, :invalid_response_format}
        end

      result ->
        if HttpFallback.down?(result) do
          Logger.warning("[headroom-down] ollama chat fell back to native direct")
          ollama_call_messages_native(url, model, messages)
        else
          case result do
            {:ok, %HTTPoison.Response{status_code: status}} -> {:error, {:http_error, status}}
            {:error, reason} -> {:error, {:connection_error, reason}}
          end
        end
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp openai_compatible_call_messages(
         endpoint,
         api_key,
         messages,
         model,
         opts,
         extra_headers,
         fallback_url \\ nil
       ) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    headers =
      [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{api_key}"}
      ] ++ extra_headers

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => messages,
        "temperature" => temperature,
        "max_tokens" => max_tokens
      })

    case HttpFallback.post_with_fallback(endpoint, fallback_url, payload, headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             completion when is_binary(completion) <-
               get_in(response, ["choices", Access.at(0), "message", "content"]) do
          {:ok,
           %{
             completion: completion,
             model_used: model,
             tokens_input: get_in(response, ["usage", "prompt_tokens"]) || 0,
             tokens_output: get_in(response, ["usage", "completion_tokens"]) || 0
           }}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.warning("OpenAI-compatible call failed: status=#{status}, body=#{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp anthropic_call_messages(api_key, messages, model, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    payload =
      Jason.encode!(%{
        "model" => model,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "messages" => messages
      })

    case HttpFallback.post_with_fallback(
           anthropic_url(),
           anthropic_fallback_url(),
           payload,
           headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             text_block when is_binary(text_block) <-
               response
               |> Map.get("content", [])
               |> Enum.find(&(&1["type"] == "text"))
               |> then(& &1["text"]) do
          {:ok,
           %{
             completion: text_block,
             model_used: model,
             tokens_input: get_in(response, ["usage", "input_tokens"]) || 0,
             tokens_output: get_in(response, ["usage", "output_tokens"]) || 0
           }}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  # Vision provider chain traversal

  defp try_vision_providers([], _image_data, _image_url, _prompt, _opts) do
    {:error, :no_providers_available}
  end

  defp try_vision_providers([provider | rest], image_data, image_url, prompt, opts) do
    case call_vision_provider(provider, image_data, image_url, prompt, opts) do
      {:ok, result} ->
        Logger.info("LLM vision provider #{provider} succeeded, model=#{result.model_used}")
        {:ok, Map.put(result, :provider, provider)}

      {:error, reason} ->
        Logger.warning("Vision provider #{provider} failed: #{inspect(reason)}, trying next")
        try_vision_providers(rest, image_data, image_url, prompt, opts)
    end
  end

  defp call_vision_provider(:ollama_vision, image_data, _image_url, prompt, _opts) do
    case health_checker_module().best_ollama_node(:heavy) do
      {:ok, {url, _}} ->
        model = System.get_env("OLLAMA_VISION_MODEL", "llava:latest")

        case ollama_vision_call(url, model, image_data, prompt) do
          {:ok, analysis} -> {:ok, %{completion: analysis, model_used: model}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp call_vision_provider(:anthropic_vision, image_data, _image_url, prompt, opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY")
    model = System.get_env("ANTHROPIC_MODEL_HEAVY", "claude-3-5-sonnet-latest")

    case api_key do
      nil -> {:error, :provider_not_configured}
      key -> anthropic_vision_call(key, model, image_data, prompt, opts)
    end
  end

  defp call_vision_provider(:openrouter_vision, image_data, image_url, prompt, opts) do
    api_key = System.get_env("OPENROUTER_API_KEY")
    model = System.get_env("OPENROUTER_VISION_MODEL", "openai/gpt-4-vision")

    case api_key do
      nil -> {:error, :provider_not_configured}
      key -> openrouter_vision_call(key, model, image_data, image_url, prompt, opts)
    end
  end

  defp call_vision_provider(_provider, _image_data, _image_url, _prompt, _opts) do
    {:error, :unknown_provider}
  end

  defp ollama_vision_call(url, model, image_data, prompt) when is_binary(image_data) do
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = ollama_timeout_ms()

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [
          %{
            "role" => "user",
            "content" => prompt,
            "images" => [image_data]
          }
        ],
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: timeout_ms, timeout: timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             analysis when is_binary(analysis) <- get_in(response, ["message", "content"]) do
          {:ok, analysis}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp ollama_vision_call(_url, _model, nil, _prompt) do
    {:error, :no_image_data}
  end

  defp anthropic_vision_call(api_key, model, image_data, prompt, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2000)

    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    # Build content array with image if provided
    content =
      if is_binary(image_data) do
        [
          %{
            "type" => "image",
            "source" => %{
              "type" => "base64",
              "media_type" => "image/png",
              "data" => image_data
            }
          },
          %{"type" => "text", "text" => prompt}
        ]
      else
        [%{"type" => "text", "text" => prompt}]
      end

    payload =
      Jason.encode!(%{
        "model" => model,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "messages" => [%{"role" => "user", "content" => content}]
      })

    case HttpFallback.post_with_fallback(
           anthropic_url(),
           anthropic_fallback_url(),
           payload,
           headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             text_block when is_binary(text_block) <-
               response
               |> Map.get("content", [])
               |> Enum.find(&(&1["type"] == "text"))
               |> then(& &1["text"]) do
          {:ok,
           %{
             completion: text_block,
             model_used: model,
             tokens_input: get_in(response, ["usage", "input_tokens"]) || 0,
             tokens_output: get_in(response, ["usage", "output_tokens"]) || 0
           }}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp openrouter_vision_call(api_key, model, image_data, image_url, prompt, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2000)

    headers = build_openrouter_headers(api_key)
    content = build_vision_content(image_data, image_url, prompt)

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => content}],
        "temperature" => temperature,
        "max_tokens" => max_tokens
      })

    make_openrouter_vision_request(payload, headers, model)
  rescue
    _ -> {:error, :request_failed}
  end

  defp build_openrouter_headers(api_key) do
    [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://github.com/ergon-automation-labs"}
    ]
  end

  defp build_vision_content(image_data, image_url, prompt) do
    case {is_binary(image_data), is_binary(image_url)} do
      {true, _} ->
        [
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:image/png;base64,#{image_data}"}
          },
          %{"type" => "text", "text" => prompt}
        ]

      {false, true} ->
        [
          %{"type" => "image_url", "image_url" => %{"url" => image_url}},
          %{"type" => "text", "text" => prompt}
        ]

      _ ->
        [%{"type" => "text", "text" => prompt}]
    end
  end

  defp make_openrouter_vision_request(payload, headers, model) do
    case HTTPoison.post(
           "https://openrouter.ai/api/v1/chat/completions",
           payload,
           headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parse_openrouter_vision_response(body, model)

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.warning("OpenRouter vision call failed: status=#{status}, body=#{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp parse_openrouter_vision_response(body, model) do
    with {:ok, response} <- Jason.decode(body),
         analysis when is_binary(analysis) <-
           get_in(response, ["choices", Access.at(0), "message", "content"]) do
      {:ok,
       %{
         completion: analysis,
         model_used: model,
         tokens_input: get_in(response, ["usage", "prompt_tokens"]) || 0,
         tokens_output: get_in(response, ["usage", "completion_tokens"]) || 0
       }}
    else
      _ -> {:error, :invalid_response_format}
    end
  end

  # Embedding providers

  defp try_embed_providers(providers, text, ollama_model, openrouter_model) do
    case try_embed_chain(providers, text, ollama_model, openrouter_model) do
      {:ok, result} ->
        Logger.info("Embedding provider succeeded, model=#{result.model_used}")
        {:ok, result}

      {:error, reason} ->
        Logger.warning("All embedding providers failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp try_embed_chain([], _text, _ollama_model, _openrouter_model) do
    {:error, :no_providers_available}
  end

  defp try_embed_chain([provider | rest], text, ollama_model, openrouter_model) do
    model_for_call =
      case provider do
        :ollama_embed -> ollama_model
        :openrouter_embed -> openrouter_model
      end

    cb_provider =
      case provider do
        :ollama_embed -> :ollama
        :openrouter_embed -> :openrouter
      end

    if BotArmyLlm.CircuitBreaker.allow?(cb_provider) == :ok do
      case call_embed_provider(provider, text, model_for_call) do
        {:ok, result} ->
          BotArmyLlm.CircuitBreaker.record_success(cb_provider)
          {:ok, Map.put(result, :model_used, model_for_call)}

        {:error, :rate_limited} ->
          BotArmyLlm.CircuitBreaker.record_failure(cb_provider, :rate_limited)
          Logger.warning("Embed provider #{provider} rate limited, trying next")
          Process.sleep(100)
          try_embed_chain(rest, text, ollama_model, openrouter_model)

        {:error, reason} ->
          BotArmyLlm.CircuitBreaker.record_failure(cb_provider, reason)
          Logger.warning("Embed provider #{provider} failed: #{inspect(reason)}, trying next")
          try_embed_chain(rest, text, ollama_model, openrouter_model)
      end
    else
      Logger.warning("Embed provider #{provider} circuit open, skipping")
      try_embed_chain(rest, text, ollama_model, openrouter_model)
    end
  end

  defp call_embed_provider(:ollama_embed, text, model) do
    case health_checker_module().best_ollama_node(:light) do
      {:ok, {url, _}} ->
        ollama_embed_call(url, model, text)

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp call_embed_provider(:openrouter_embed, text, model) do
    api_key = System.get_env("OPENROUTER_API_KEY")

    case api_key do
      nil -> {:error, :provider_not_configured}
      key -> openrouter_embed_call(key, model, text)
    end
  end

  defp ollama_embed_call(url, model, text) do
    endpoint = "#{url}/api/embed"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = EmbeddingConfig.ollama_embed_timeout_ms()

    payload =
      Jason.encode!(%{
        "model" => model,
        "input" => text
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: timeout_ms, timeout: timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             {:ok, embedding} <- extract_ollama_embedding(response) do
          {:ok, %{embedding: embedding}}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  # Ollama has returned both of these shapes across versions/endpoints:
  #   %{ "embedding" => [float, ...] }
  #   %{ "embeddings" => [[float, ...], ...] }
  defp extract_ollama_embedding(%{"embedding" => embedding}) when is_list(embedding),
    do: {:ok, embedding}

  defp extract_ollama_embedding(%{"embeddings" => [embedding | _]}) when is_list(embedding),
    do: {:ok, embedding}

  defp extract_ollama_embedding(_), do: {:error, :invalid_response_format}

  defp openrouter_embed_call(api_key, model, text) do
    url = EmbeddingConfig.openrouter_embeddings_url()
    timeout_ms = EmbeddingConfig.openrouter_embed_timeout_ms()

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://github.com/ergon-automation-labs"}
    ]

    payload =
      Jason.encode!(%{
        "model" => model,
        "input" => text
      })

    case HTTPoison.post(
           url,
           payload,
           headers,
           recv_timeout: timeout_ms,
           timeout: timeout_ms
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        with {:ok, response} <- Jason.decode(body),
             embedding when is_list(embedding) <-
               get_in(response, ["data", Access.at(0), "embedding"]) do
          {:ok, %{embedding: embedding}}
        else
          _ -> {:error, :invalid_response_format}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end
end
