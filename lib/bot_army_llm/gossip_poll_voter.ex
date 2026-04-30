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
    vote = suggest_vote(topic, options, context_snapshot)

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
        "reason" => "voted_on_heartbeat_wakeup"
      }
    }

    BotArmyRuntime.NATS.Publisher.publish("gossip.poll.vote", message)
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _ -> :ok
    end
  end

  defp suggest_vote(topic, options, context_snapshot) do
    preferred =
      case topic do
        "focus" -> "deep_work"
        "risk" -> "quality"
        "coordination" -> "dependencies"
        "priorities" -> choose_priority_vote(options, context_snapshot)
        _ -> nil
      end

    cond do
      is_binary(preferred) and preferred in options -> preferred
      is_list(options) and options != [] -> List.first(options)
      true -> "upvote"
    end
  end

  defp choose_priority_vote(options, context_snapshot) do
    tasks = list_size(context_snapshot["tasks_top"])
    projects = list_size(context_snapshot["projects_top"])
    goals = list_size(context_snapshot["goals_top"])

    text =
      [
        context_snapshot["tasks_top"],
        context_snapshot["projects_top"],
        context_snapshot["goals_top"]
      ]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    preferred =
      cond do
        String.contains?(text, ["risk", "block", "fix", "incident", "hardening"]) ->
          "reduce_load"

        tasks >= 9 or projects >= 6 ->
          "reduce_load"

        String.contains?(text, ["release", "ship", "deploy", "launch"]) and tasks <= 6 and
            goals <= 3 ->
          "ship_more"

        true ->
          "protect_focus"
      end

    cond do
      preferred in options ->
        preferred

      is_list(options) and options != [] ->
        idx = :erlang.phash2(text <> ":llm", length(options))
        Enum.at(options, idx)

      true ->
        "protect_focus"
    end
  end

  defp list_size(list) when is_list(list), do: length(list)
  defp list_size(_), do: 0
end
