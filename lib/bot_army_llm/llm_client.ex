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

  alias BotArmyLlm.{ComplexityScorer, OllamaHealthChecker}

  @doc """
  Complete a prompt using the best available provider.

  Options:
    - `model`: Override model selection ("auto" uses complexity routing)
    - `temperature`: Generation temperature (default: 0.7)
    - `max_tokens`: Max response tokens (default: 1000)
  """
  def complete(text, opts \\ []) when is_binary(text) do
    start_time = System.monotonic_time(:millisecond)
    complexity = ComplexityScorer.score(text)
    providers = provider_chain(complexity)

    Logger.debug("LLM routing: complexity=#{complexity}, chain=#{inspect(providers)}")

    case try_providers(providers, text, complexity, opts) do
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

  Options:
    - `model`: Override model selection ("auto" uses complexity routing)
    - `temperature`: Generation temperature (default: 0.7)
    - `max_tokens`: Max response tokens (default: 1000)
  """
  def complete_messages(messages, opts \\ []) when is_list(messages) do
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

    providers = provider_chain(complexity)

    Logger.debug("LLM routing (messages): complexity=#{complexity}, chain=#{inspect(providers)}")

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
      start_time = System.monotonic_time(:millisecond)
      providers = [:ollama_vision, :anthropic_vision, :openrouter_vision]

      Logger.debug("LLM vision routing: chain=#{inspect(providers)}")

      case try_vision_providers(providers, image_data_base64, image_url, prompt_text, opts) do
        {:ok, result} ->
          latency = System.monotonic_time(:millisecond) - start_time
          {:ok, Map.put(result, :latency_ms, latency)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Provider chain selection

  defp provider_chain(:heavy), do: [:blackbox, :openrouter, :anthropic]
  defp provider_chain(_), do: [:ollama, :blackbox, :openrouter, :anthropic]

  # Chain traversal

  defp try_providers([], _text, _complexity, _opts) do
    {:error, :no_providers_available}
  end

  defp try_providers([provider | rest], text, complexity, opts) do
    case call_provider(provider, text, complexity, opts) do
      {:ok, result} ->
        Logger.info("LLM provider #{provider} succeeded, model=#{result.model_used}")
        {:ok, Map.put(result, :provider, provider)}

      {:error, reason} ->
        Logger.warning("Provider #{provider} failed: #{inspect(reason)}, trying next")
        try_providers(rest, text, complexity, opts)
    end
  end

  # Provider implementations

  defp call_provider(:ollama, text, complexity, _opts) do
    case OllamaHealthChecker.best_ollama_node(complexity) do
      {:ok, {url, model}} ->
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
    base_url = System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1/chat/completions")
    model = cloud_model(:openrouter, complexity)

    # OpenRouter requires HTTP-Referer header
    extra_headers = [{"HTTP-Referer", "https://github.com/ergon-automation-labs"}]

    case {api_key, model} do
      {nil, _} -> {:error, :provider_not_configured}
      {_, ""} -> {:error, :model_not_configured}
      {key, m} -> openai_compatible_call(base_url, key, text, m, opts, extra_headers)
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

  defp ollama_call(url, model, text) do
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => text}],
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: 120_000, timeout: 120_000) do
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

  # OpenAI-compatible API (blackbox.ai, openrouter)
  defp openai_compatible_call(endpoint, api_key, text, model, opts, extra_headers) do
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

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: 60_000, timeout: 60_000) do
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

    case HTTPoison.post("https://api.anthropic.com/v1/messages", payload, headers,
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
    case call_provider_messages(provider, messages, complexity, opts) do
      {:ok, result} ->
        Logger.info("LLM provider #{provider} succeeded (messages), model=#{result.model_used}")
        {:ok, Map.put(result, :provider, provider)}

      {:error, reason} ->
        Logger.warning("Provider #{provider} failed (messages): #{inspect(reason)}, trying next")
        try_providers_messages(rest, messages, complexity, opts)
    end
  end

  defp call_provider_messages(:ollama, messages, _complexity, _opts) do
    case OllamaHealthChecker.best_ollama_node(:medium) do
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
    base_url = System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1/chat/completions")
    model = cloud_model(:openrouter, complexity)
    extra_headers = [{"HTTP-Referer", "https://github.com/ergon-automation-labs"}]

    case {api_key, model} do
      {nil, _} -> {:error, :provider_not_configured}
      {_, ""} -> {:error, :model_not_configured}
      {key, m} -> openai_compatible_call_messages(base_url, key, messages, m, opts, extra_headers)
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
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => messages,
        "stream" => false
      })

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: 120_000, timeout: 120_000) do
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

  defp openai_compatible_call_messages(endpoint, api_key, messages, model, opts, extra_headers) do
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

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: 60_000, timeout: 60_000) do
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

    case HTTPoison.post("https://api.anthropic.com/v1/messages", payload, headers,
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
    case OllamaHealthChecker.best_ollama_node(:heavy) do
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

    case HTTPoison.post(endpoint, payload, headers, recv_timeout: 120_000, timeout: 120_000) do
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

    case HTTPoison.post("https://api.anthropic.com/v1/messages", payload, headers,
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

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://github.com/ergon-automation-labs"}
    ]

    # Build content array
    content =
      case {is_binary(image_data), is_binary(image_url)} do
        {true, _} ->
          [
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,#{image_data}"}},
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

    payload =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => content}],
        "temperature" => temperature,
        "max_tokens" => max_tokens
      })

    case HTTPoison.post(
           "https://openrouter.ai/api/v1/chat/completions",
           payload,
           headers,
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
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

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.warning("OpenRouter vision call failed: status=#{status}, body=#{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end
end
