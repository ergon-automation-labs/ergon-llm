defmodule BotArmyLlm.Handlers.SkillExecuteHandler do
  @moduledoc """
  Executes Skills bot workflows through a stable LLM proxy request/reply API.

  Subject: `llm.skill.execute`
  """

  require Logger
  alias BotArmyLlm.NATS.Publisher

  @skills_subject_prefix "bot.army.skills.command."
  @default_timeout_ms 90_000
  @min_timeout_ms 90_000

  @spec handle_execute(map(), String.t()) :: :ok
  def handle_execute(message, reply_to) do
    request = message["payload"] || message

    with {:ok, slug} <- extract_slug(request),
         {:ok, payload_text} <- extract_payload_text(request),
         {:ok, response} <- execute_skill(slug, payload_text, request, message) do
      publish_reply(reply_to, response)
    else
      {:error, reason} ->
        Logger.warning("[SkillExecuteHandler] Failed skill execution request: #{inspect(reason)}")
        publish_reply(reply_to, error_response(reason))
    end
  end

  defp extract_slug(%{"slug" => slug}) when is_binary(slug) and slug != "", do: {:ok, slug}
  defp extract_slug(_), do: {:error, {:missing_field, "slug"}}

  defp extract_payload_text(%{"payload_text" => payload_text})
       when is_binary(payload_text) and payload_text != "" do
    {:ok, payload_text}
  end

  defp extract_payload_text(%{"payload" => %{"text" => payload_text}})
       when is_binary(payload_text) and payload_text != "" do
    {:ok, payload_text}
  end

  defp extract_payload_text(_), do: {:error, {:missing_field, "payload_text"}}

  defp execute_skill(slug, payload_text, request, message) do
    subject = @skills_subject_prefix <> slug
    timeout_ms = parse_timeout_ms(request)

    envelope = %{
      "event" => subject,
      "event_id" => UUID.uuid4(),
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => Map.get(request, "source", "llm_proxy"),
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => Map.get(request, "triggered_by", "llm_skill_execute"),
      "tenant_id" => Map.get(request, "tenant_id", Map.get(message, "tenant_id")),
      "user_id" => Map.get(request, "user_id", Map.get(message, "user_id")),
      "payload" => %{"text" => payload_text}
    }

    case BotArmyRuntime.NATS.Publisher.request(
           subject,
           envelope,
           timeout_ms: timeout_ms,
           max_retries: 0,
           retry_base_ms: 150,
           circuit_breaker_key: "llm.skill.execute"
         ) do
      {:ok, %{"status" => "success", "payload" => %{"completion" => completion}} = raw} ->
        {:ok,
         %{
           "status" => "success",
           "slug" => slug,
           "completion" => completion,
           "raw_payload" => raw
         }}

      {:ok, %{"status" => "error", "error" => error} = raw} ->
        {:ok,
         %{
           "status" => "error",
           "slug" => slug,
           "error" => error,
           "raw_payload" => raw
         }}

      {:ok, raw} ->
        {:ok,
         %{
           "status" => "error",
           "slug" => slug,
           "error" => "Unexpected skills response shape",
           "raw_payload" => raw
         }}

      {:error, reason} ->
        Logger.warning("[SkillExecuteHandler] Skills request failed",
          slug: slug,
          subject: subject,
          timeout_ms: timeout_ms,
          reason: inspect(reason)
        )

        {:error, {:skills_request_failed, reason}}
    end
  end

  defp parse_timeout_ms(request) do
    requested_timeout_ms =
      case request["timeout_ms"] do
        ms when is_integer(ms) and ms > 0 ->
          ms

        ms when is_binary(ms) ->
          case Integer.parse(ms) do
            {parsed, ""} when parsed > 0 -> parsed
            _ -> @default_timeout_ms
          end

        _ ->
          @default_timeout_ms
      end

    max(requested_timeout_ms, @min_timeout_ms)
  end

  defp error_response(reason) do
    %{
      "status" => "error",
      "error" => format_reason(reason)
    }
  end

  defp format_reason({:missing_field, field}), do: "Missing required field: #{field}"

  defp format_reason({:skills_request_failed, reason}),
    do: "Skills request failed: #{inspect(reason)}"

  defp format_reason(other), do: inspect(other)

  defp publish_reply(reply_to, response) do
    with {:ok, conn} <- GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000),
         {:ok, body} <- Jason.encode(response) do
      Gnat.pub(conn, reply_to, body)
    else
      {:error, reason} ->
        Logger.error("[SkillExecuteHandler] Failed to publish reply: #{inspect(reason)}")
    end
  end
end
