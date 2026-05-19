defmodule BotArmyLlm.GossipPollVoter do
  @moduledoc false

  @table :llm_gossip_poll_state

  def handle_poll_broadcast(message) when is_map(message) do
    ensure_table!()
    payload = Map.get(message, "payload", %{})
    poll_id = Map.get(payload, "poll_id")
    topic = Map.get(payload, "topic", "general")
    options = Map.get(payload, "options", [])
    context_snapshot = Map.get(payload, "context_snapshot", %{})
    ttl_seconds = Map.get(payload, "ttl_seconds", 60)

    if is_binary(poll_id) and poll_id != "" do
      expires_at = System.system_time(:second) + ttl_seconds

      :ets.insert(
        @table,
        {:active_poll,
         %{
           poll_id: poll_id,
           topic: topic,
           options: options,
           context_snapshot: context_snapshot,
           expires_at: expires_at
         }}
      )
    end
  end

  def maybe_vote_on_heartbeat do
    ensure_table!()

    case :ets.lookup(@table, :active_poll) do
      [
        {:active_poll,
         %{
           poll_id: poll_id,
           topic: topic,
           options: options,
           context_snapshot: context_snapshot,
           expires_at: expires_at
         }}
      ] ->
        now = System.system_time(:second)
        voted_key = {:voted, poll_id}

        cond do
          now > expires_at ->
            :ets.delete(@table, :active_poll)
            :ok

          :ets.lookup(@table, voted_key) != [] ->
            :ok

          true ->
            publish_poll_vote(poll_id, topic, options, context_snapshot)
            :ets.insert(@table, {voted_key, true})
        end

      _ ->
        :ok
    end
  end

  defp publish_poll_vote(poll_id, topic, options, context_snapshot) do
    vote = llm_vote_or_fallback(topic, options, context_snapshot)

    message = %{
      "event_id" => UUID.uuid4(),
      "event" => "gossip.poll.vote",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "tenant_id" => BotArmyRuntime.Tenant.default_tenant_id(),
      "conversation_id" => poll_id,
      "payload" => %{
        "poll_id" => poll_id,
        "topic" => topic,
        "voter" => "llm_bot",
        "vote" => vote,
        "reason" => "heartbeat_deliberation"
      }
    }

    Publisher.publish("gossip.poll.vote", message)
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _ -> :ok
    end
  end

  defp llm_vote_or_fallback(topic, options, context_snapshot) do
    prompt = """
    You are the LLM bot. Poll topic: "#{topic}". Options: #{Enum.join(options, ", ")}.
    Context: #{inspect(context_snapshot)}.
    Reply JSON only: {"vote": "<option>", "reason": "<one sentence>"}
    """

    case BotArmyLlm.LlmClient.complete(prompt, model: :fast) do
      {:ok, %{text: text}} ->
        handle_llm_response(text, topic, options, context_snapshot)

      _ ->
        suggest_vote(topic, options, context_snapshot)
    end
  end

  defp handle_llm_response(text, topic, options, context_snapshot) do
    case Jason.decode(text) do
      {:ok, %{"vote" => v}} when is_binary(v) ->
        if Enum.member?(options, v),
          do: v,
          else: suggest_vote(topic, options, context_snapshot)

      _ ->
        suggest_vote(topic, options, context_snapshot)
    end
  end

  defp suggest_vote(topic, options, context_snapshot) do
    preferred = topic_preference(topic, options, context_snapshot)
    select_best_option(preferred, options)
  end

  defp topic_preference("focus", _options, _context), do: "deep_work"
  defp topic_preference("risk", _options, _context), do: "quality"
  defp topic_preference("coordination", _options, _context), do: "dependencies"

  defp topic_preference("priorities", options, context),
    do: choose_priority_vote(options, context)

  defp topic_preference(_, _options, _context), do: nil

  defp select_best_option(preferred, options) when is_binary(preferred) do
    if Enum.member?(options, preferred), do: preferred, else: select_best_option(nil, options)
  end

  defp select_best_option(_preferred, options) when is_list(options) and options != [] do
    List.first(options)
  end

  defp select_best_option(_preferred, _options) do
    "upvote"
  end

  defp choose_priority_vote(options, context_snapshot) do
    BotArmyRuntime.GossipPollAffinity.choose_priority_vote(
      options,
      context_snapshot,
      :llm,
      ":llm"
    )
  end
end
