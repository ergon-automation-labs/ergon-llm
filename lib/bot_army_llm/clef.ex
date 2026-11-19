defmodule BotArmyLlm.Clef do
  @moduledoc """
  Fast decisions: Cloudflare's Clef decision models, through Ollama's `/v1/systemone`.

  Clef does not write text. It takes a `state` and up to 64 typed questions and scores every
  answer in one pass — `choice` (one option, with probabilities), `noul` (the probability
  something is true), `score` (a level on a 2–10 step scale). That makes it the fast half of a
  two-speed caller: Clef decides what kind of answer is wanted, a chat model writes it.

  ## Where it runs is the pillar's

  `CLEF_MODELS` (rendered by salt from `llm:clef`) is a JSON object with up to three entries:

      {"local": {"model": "clef-flash", "node": ""},
       "large": {"model": "clef",       "node": "mini"},
       "cloud": {"model": "clef:cloud", "node": ""}}

  A request picks one with `"where"` (default `"local"`): `local` is the fast small model,
  `large` the 27B where it has room (mini), `cloud` ollama.com. All are called through an Ollama
  node — the cloud model through a local Ollama signed in to ollama.com — so a blank node is
  `OLLAMA_URL` and `"mini"` is `OLLAMA_MINI_URL`. A `where` that is not configured is refused by
  name (`{:model_not_configured, {:clef, where}}`), never answered by another one: the cloud
  entry sends the state off the machine, so it must be asked for, not fallen back to.

  Each `where` has its own breaker (`:clef_local`, `:clef_large`, `:clef_cloud`), and none falls
  back to a chat model — a chat model cannot return Clef's probabilities.

  The state is the caller's, and may be private: it is never logged, and no error carries it.
  """

  require Logger

  alias BotArmyLlm.CircuitBreaker

  @wheres %{"local" => :clef_local, "large" => :clef_large, "cloud" => :clef_cloud}
  @types ~w(choice noul score)
  @max_questions 64
  @default_timeout_ms 60_000

  @type reply :: %{String.t() => term()}

  @doc "The breaker names, one per `where`."
  @spec breakers() :: [atom()]
  def breakers, do: Map.values(@wheres)

  @doc """
  Ask Clef. `request` is the caller's map (`state`, `questions`, optional `images`, `where`).

  `opts[:post]` is the HTTP call, `(url, json_body, timeout_ms) -> {:ok, status, body} |
  {:error, reason}`; it is injectable so the contract is testable without a model.
  """
  @spec decide(map(), keyword()) :: {:ok, reply()} | {:error, term()}
  def decide(request, opts \\ []) when is_map(request) do
    post = Keyword.get(opts, :post, &http_post/3)

    with {:ok, where} <- where(request),
         :ok <- validate(request),
         {:ok, %{"model" => model, "node" => node}} <- entry(where),
         {:ok, url} <- node_url(node) do
      breaker = Map.fetch!(@wheres, where)

      case CircuitBreaker.allow?(breaker) do
        :ok -> call(breaker, where, model, url <> "/v1/systemone", body(request, model), post)
        {:open, retry_after_ms} -> {:error, {:circuit_open, breaker, retry_after_ms}}
      end
    end
  end

  defp where(request) do
    case Map.get(request, "where", "local") do
      w when is_map_key(@wheres, w) ->
        {:ok, w}

      other ->
        {:error,
         {:invalid_request,
          "where must be \"local\", \"large\" or \"cloud\", got #{inspect(other)}"}}
    end
  end

  defp validate(request) do
    with :ok <- validate_state(Map.get(request, "state")),
         :ok <- validate_questions(Map.get(request, "questions")) do
      validate_images(Map.get(request, "images"))
    end
  end

  defp validate_state(state) when is_binary(state) and state != "", do: :ok
  defp validate_state(state) when is_map(state) or is_list(state), do: :ok

  defp validate_state(_),
    do: {:error, {:invalid_request, "state is required (text, object or array)"}}

  defp validate_questions(qs) when is_map(qs) and map_size(qs) in 1..@max_questions do
    Enum.find_value(qs, :ok, fn {name, q} ->
      case validate_question(q) do
        :ok -> nil
        {:error, why} -> {:error, {:invalid_request, "question #{inspect(name)}: #{why}"}}
      end
    end)
  end

  defp validate_questions(qs) when is_map(qs),
    do:
      {:error,
       {:invalid_request,
        "questions must have 1 to #{@max_questions} entries, got #{map_size(qs)}"}}

  defp validate_questions(_),
    do: {:error, {:invalid_request, "questions is required (an object of named questions)"}}

  defp validate_question(%{"type" => type} = q) when type in @types do
    case q["instructions"] do
      text when is_binary(text) and text != "" -> :ok
      _ -> {:error, "instructions is required"}
    end
  end

  defp validate_question(%{"type" => type}),
    do: {:error, "type must be one of #{Enum.join(@types, ", ")}, got #{inspect(type)}"}

  defp validate_question(_), do: {:error, "must be an object with type and instructions"}

  defp validate_images(nil), do: :ok

  defp validate_images(images) when is_list(images) do
    if Enum.all?(images, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_request, "images must be base64 strings"}}
  end

  defp validate_images(_),
    do: {:error, {:invalid_request, "images must be a list of base64 strings"}}

  @doc "The configured `%{\"model\", \"node\"}` for a `where`, or the refusal."
  @spec entry(String.t()) :: {:ok, map()} | {:error, {:model_not_configured, {:clef, String.t()}}}
  def entry(where) do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get("CLEF_MODELS"),
         {:ok, %{} = all} <- Jason.decode(raw),
         %{"model" => model} = e when is_binary(model) and model != "" <- Map.get(all, where) do
      {:ok, %{"model" => model, "node" => Map.get(e, "node") || ""}}
    else
      _ -> {:error, {:model_not_configured, {:clef, where}}}
    end
  end

  defp node_url(node) do
    case String.trim(node) do
      "" -> {:ok, config_url("OLLAMA_URL", "http://127.0.0.1:11434")}
      "mini" -> mini_url()
      other -> {:error, {:unknown_node, other}}
    end
  end

  defp mini_url do
    case config_url("OLLAMA_MINI_URL", "") do
      "" -> {:error, {:unknown_node, "mini"}}
      url -> {:ok, url}
    end
  end

  defp config_url(key, default),
    do:
      key
      |> BotArmyLibraryRuntime.ConfigLoader.get(default)
      |> to_string()
      |> String.trim_trailing("/")

  defp body(request, model) do
    request
    |> Map.take(["state", "questions", "images"])
    |> Map.put("model", model)
    |> Jason.encode!()
  end

  defp call(breaker, where, model, url, body, post) do
    case post.(url, body, timeout_ms()) do
      {:ok, 200, raw} ->
        CircuitBreaker.record_success(breaker)
        answer(raw, where, model)

      {:ok, status, raw} ->
        if status >= 500, do: CircuitBreaker.record_failure(breaker, {:http, status})
        {:error, {:clef_http, status, detail(raw)}}

      {:error, reason} ->
        CircuitBreaker.record_failure(breaker, reason)
        Logger.warning("[Clef] #{where} call failed: #{inspect(reason)}")
        {:error, {:clef_unreachable, reason}}
    end
  end

  defp answer(raw, where, model) do
    case Jason.decode(raw) do
      {:ok, %{"answers" => %{} = answers} = decoded} ->
        {:ok,
         %{
           "where" => where,
           "model" => decoded["model"] || model,
           "answers" => answers,
           "usage" => decoded["usage"] || %{}
         }}

      _ ->
        {:error, :clef_bad_answer}
    end
  end

  # Ollama's error bodies are its own words ({"error": "..."}), never the state; keep only that.
  defp detail(raw) do
    case Jason.decode(raw) do
      {:ok, %{"error" => msg}} when is_binary(msg) -> String.slice(msg, 0, 200)
      _ -> "#{byte_size(raw)} bytes"
    end
  end

  defp timeout_ms do
    with raw when is_binary(raw) <- BotArmyLibraryRuntime.ConfigLoader.get("CLEF_TIMEOUT_MS"),
         {n, ""} when n > 0 <- Integer.parse(raw) do
      n
    else
      _ -> @default_timeout_ms
    end
  end

  defp http_post(url, body, timeout_ms) do
    case HTTPoison.post(url, body, [{"content-type", "application/json"}],
           recv_timeout: timeout_ms,
           timeout: timeout_ms
         ) do
      {:ok, %HTTPoison.Response{status_code: status, body: resp}} -> {:ok, status, resp}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
    end
  end
end
