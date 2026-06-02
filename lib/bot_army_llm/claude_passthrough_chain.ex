defmodule BotArmyLlm.ClaudePassthroughChain do
  @moduledoc """
  Configurable provider chain for Claude Code–style Anthropic Messages requests.

  **Non-streaming** requests use `run/1`. **Streaming** (`stream: true`) uses the same chain order
  via `stream_chain_steps/0` and `BotArmyLlm.ClaudePassthroughStream`.

  ## Configuration

  Set **`BOT_ARMY_LLM_CLAUDE_CHAIN`** to a comma-separated list (order = try order):

  - `blackbox` — OpenAI-compatible `BLACKBOX_BASE_URL` + `BLACKBOX_API_KEY`
  - `openrouter` — OpenRouter chat completions + `OPENROUTER_API_KEY`
  - `anthropic` — native Messages API + `ANTHROPIC_API_KEY`
  - `ollama` — local Ollama `/api/chat` via `AnthropicOllamaAdapter` (text-only); same as other
    steps: runs when reached in order and the previous step failed (omit from the chain to skip)

  **Default:** `openrouter,anthropic,ollama`

  Override in tests: `config :bot_army_llm, :claude_passthrough_chain, [:anthropic]`

  ## OpenAI-compatible steps

  Blackbox and OpenRouter use `AnthropicMessagesToOpenaiChat.to_chat_completion_request/1`
  (text + **tools** / tool_result → OpenAI chat). On conversion errors, the chain tries the next step.
  """

  require Logger

  alias BotArmyLlm.{
    AnthropicMessagesToOpenaiChat,
    AnthropicOllamaAdapter,
    ChatCompletionToAnthropic
  }

  @default_chain "openrouter,anthropic,ollama"

  @doc false
  @spec run(map()) :: {:ok, String.t()} | {:error, term()}
  def run(payload) when is_map(payload) do
    case resolved_chain() do
      {:ok, steps} -> run_steps(steps, payload, nil)
      {:error, _} = err -> err
    end
  end

  defp resolved_chain do
    stream_chain_steps()
  end

  @doc false
  @spec stream_chain_steps() :: {:ok, list(atom())} | {:error, term()}
  def stream_chain_steps do
    case Application.get_env(:bot_army_llm, :claude_passthrough_chain) do
      list when is_list(list) and list != [] ->
        {:ok, list}

      _ ->
        parse_chain_string(System.get_env("BOT_ARMY_LLM_CLAUDE_CHAIN", @default_chain))
    end
  end

  @doc false
  def parse_chain_string(str) when is_binary(str) do
    steps =
      str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)

    Enum.reduce_while(steps, {:ok, []}, fn word, {:ok, acc} ->
      case word do
        "blackbox" -> {:cont, {:ok, acc ++ [:blackbox]}}
        "openrouter" -> {:cont, {:ok, acc ++ [:openrouter]}}
        "anthropic" -> {:cont, {:ok, acc ++ [:anthropic]}}
        "ollama" -> {:cont, {:ok, acc ++ [:ollama]}}
        _ -> {:halt, {:error, {:unknown_claude_chain_step, word}}}
      end
    end)
  end

  defp run_steps([], _payload, last_err) do
    {:error, last_err || :claude_passthrough_exhausted}
  end

  defp run_steps([step | rest], payload, _prev_err) do
    case dispatch(step, payload) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        Logger.debug("Claude passthrough step #{step} failed: #{inspect(reason)}")
        run_steps(rest, payload, reason)
    end
  end

  defp dispatch(:blackbox, payload), do: try_blackbox(payload)
  defp dispatch(:openrouter, payload), do: try_openrouter(payload)
  defp dispatch(:anthropic, payload), do: try_anthropic_direct(payload)
  defp dispatch(:ollama, payload), do: try_ollama(payload)

  defp try_blackbox(payload) do
    api_key = System.get_env("BLACKBOX_API_KEY")
    url = System.get_env("BLACKBOX_BASE_URL", "https://api.blackbox.ai/api/chat")

    model =
      System.get_env("BLACKBOX_MODEL_CLAUDE_CODE") ||
        System.get_env("BLACKBOX_MODEL_MEDIUM", "qwen/qwen3-32b:free")

    case api_key do
      nil -> {:error, {:provider_not_configured, "Blackbox"}}
      "" -> {:error, {:model_not_configured, "Blackbox"}}
      key -> chat_completions_passthrough(payload, key, url, [], model)
    end
  end

  defp try_openrouter(payload) do
    api_key = System.get_env("OPENROUTER_API_KEY")
    url = System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1/chat/completions")
    model = System.get_env("OPENROUTER_MODEL_CLAUDE_CODE", "anthropic/claude-3.5-sonnet")
    extra = [{"HTTP-Referer", "https://github.com/ergon-automation-labs"}]

    case api_key do
      nil -> {:error, {:provider_not_configured, "OpenRouter"}}
      "" -> {:error, {:model_not_configured, "OpenRouter"}}
      key -> chat_completions_passthrough(payload, key, url, extra, model)
    end
  end

  defp chat_completions_passthrough(payload, api_key, url, extra_headers, model) do
    with {:ok, %{messages: messages, tools: tools}} <-
           AnthropicMessagesToOpenaiChat.to_chat_completion_request(payload),
         body_map <- build_chat_completion_body(model, messages, tools, payload),
         {:ok, json} <- Jason.encode(body_map) do
      make_chat_completion_request(json, api_key, url, extra_headers, model)
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp build_chat_completion_body(model, messages, tools, payload) do
    body_map = %{
      "model" => model,
      "messages" => messages,
      "stream" => false
    }

    body_map =
      case tools do
        [] -> body_map
        list when is_list(list) -> Map.put(body_map, "tools", list)
      end

    body_map =
      case Map.get(payload, "temperature") do
        t when is_number(t) -> Map.put(body_map, "temperature", t)
        _ -> body_map
      end

    case Map.get(payload, "max_tokens") do
      n when is_integer(n) and n > 0 -> Map.put(body_map, "max_tokens", n)
      _ -> body_map
    end
  end

  defp make_chat_completion_request(json, api_key, url, extra_headers, model) do
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"} | extra_headers
    ]

    case HTTPoison.post(url, json, headers, recv_timeout: 120_000, timeout: 120_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp}} ->
        ChatCompletionToAnthropic.from_chat_completion_body(resp, model)

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp try_anthropic_direct(payload) do
    api_key = System.get_env("ANTHROPIC_API_KEY")
    model = System.get_env("ANTHROPIC_MODEL_CLAUDE_CODE", "claude-haiku-4-5-20251001")

    case {api_key, model} do
      {nil, _} ->
        {:error, {:provider_not_configured, "Anthropic"}}

      {_, ""} ->
        {:error, {:model_not_configured, "Anthropic"}}

      {key, m} ->
        payload_with_model =
          payload
          |> Map.put("model", m)
          |> Map.put_new("stream", false)

        anthropic_messages_api_post(key, payload_with_model)
    end
  end

  defp anthropic_messages_api_post(api_key, payload) do
    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "tools-2024-04-04"}
    ]

    case Jason.encode(payload) do
      {:ok, body} ->
        case HTTPoison.post("https://api.anthropic.com/v1/messages", body, headers,
               recv_timeout: 120_000,
               timeout: 120_000
             ) do
          {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
            {:ok, response_body}

          {:ok, %HTTPoison.Response{status_code: 429}} ->
            {:error, :rate_limited}

          {:ok, %HTTPoison.Response{status_code: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, {:connection_error, reason}}
        end

      {:error, reason} ->
        {:error, {:encode_error, reason}}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp try_ollama(payload) do
    model = ollama_fallback_model()
    # Map models that don't support /api/chat to ones that do
    model = map_unsupported_ollama_model(model)
    Logger.warning("try_ollama: using model=#{model}")

    result =
      with {:ok, ollama_messages} <- AnthropicOllamaAdapter.to_ollama_messages(payload),
           {:ok, {url, _node_model}} <- BotArmyLlm.OllamaHealthChecker.best_ollama_node(:medium),
           {:ok, raw_body} <- ollama_chat_completion_raw(url, model, ollama_messages, payload) do
        Logger.warning("try_ollama: sending to #{url}: messages count=#{length(ollama_messages)}")
        AnthropicOllamaAdapter.anthropic_json_from_ollama_chat(raw_body, model)
      end

    case result do
      {:error, {:ollama_http_error, status}} ->
        Logger.warning("Ollama HTTP #{status} - check logs above for response body")
        {:error, {:http_error, status}}

      other ->
        other
    end
  end

  defp ollama_fallback_model do
    System.get_env("OLLAMA_MODEL_CLAUDE_FALLBACK") ||
      System.get_env("OLLAMA_MODEL_MEDIUM", "llama3.1:8b-instruct-q6_K")
  end

  defp map_unsupported_ollama_model(model) do
    case model do
      "ministral-" <> _rest -> "llama3.1:8b-instruct-q6_K"
      "qwen3" <> _rest -> "llama3.1:8b-instruct-q6_K"
      other -> other
    end
  end

  defp ollama_chat_completion_raw(url, model, messages, anthropic_payload) do
    endpoint = "#{url}/api/chat"
    headers = [{"Content-Type", "application/json"}]
    timeout_ms = ollama_timeout_ms()

    base = build_ollama_request_body(model, messages, anthropic_payload)

    with {:ok, body} <- Jason.encode(base) do
      Logger.warning("[Ollama] Sending request to #{endpoint}: #{String.slice(body, 0, 300)}")
      make_ollama_request(endpoint, body, headers, timeout_ms)
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp build_ollama_request_body(model, messages, anthropic_payload) do
    base = %{
      "model" => model,
      "messages" => messages,
      "stream" => false
    }

    base =
      case Map.get(anthropic_payload, "temperature") do
        t when is_number(t) -> put_ollama_options(base, %{"temperature" => t})
        _ -> base
      end

    case Map.get(anthropic_payload, "max_tokens") do
      n when is_integer(n) and n > 0 -> put_ollama_options(base, %{"num_predict" => n})
      _ -> base
    end
  end

  defp make_ollama_request(endpoint, body, headers, timeout_ms) do
    case HTTPoison.post(endpoint, body, headers,
           recv_timeout: timeout_ms,
           timeout: timeout_ms
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
        Logger.warning("Ollama HTTP #{status}: #{String.slice(resp_body, 0, 200)}")
        {:error, {:ollama_http_error, status}}

      {:error, reason} ->
        Logger.warning("Ollama connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp put_ollama_options(%{"options" => o} = m, extra),
    do: %{m | "options" => Map.merge(o, extra)}

  defp put_ollama_options(m, extra), do: Map.put(m, "options", extra)

  defp ollama_timeout_ms do
    case System.get_env("OLLAMA_TIMEOUT_MS") do
      nil -> 600_000
      v -> String.to_integer(v)
    end
  rescue
    _ -> 600_000
  end
end
