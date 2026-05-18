defmodule BotArmyLlm.Handlers.SubtaskHandler do
  @moduledoc """
  Handles distributed subtask execution from Dispatcher Orchestrator.

  Receives subtask intents from the dispatcher and executes them autonomously.
  Part of Phase 2: Autonomous Task Decomposition infrastructure.

  Expected payload:
  ```
  {
    "subtask_id": "uuid",
    "decomposition_id": "uuid",
    "description": "What to do",
    "task_payload": {
      "query": "...",
      "model": "...",
      ...
    }
  }
  ```

  Publishes `dispatcher.subtask.completed` with results.
  """

  require Logger
  alias BotArmyRuntime.NATS.Publisher
  alias BotArmyLlm.EventBuilder

  @doc """
  Handle a dispatcher subtask intent for LLM inference.
  """
  def handle_subtask_intent(message) do
    event_id = message["event_id"]
    payload = message["payload"]
    subtask_id = payload["subtask_id"]
    decomposition_id = payload["decomposition_id"]
    task_payload = payload["task_payload"] || %{}

    Logger.info("[SubtaskHandler] Processing subtask",
      subtask_id: subtask_id,
      decomposition_id: decomposition_id
    )

    case execute_task(task_payload) do
      {:ok, result} ->
        publish_completion(subtask_id, decomposition_id, "completed", result)

      {:error, reason} ->
        Logger.warning("[SubtaskHandler] Task failed",
          subtask_id: subtask_id,
          reason: inspect(reason)
        )

        publish_completion(subtask_id, decomposition_id, "failed", %{"error" => inspect(reason)})
    end
  end

  # Private: Execute the actual task
  defp execute_task(task_payload) do
    query = Map.get(task_payload, "query") || Map.get(task_payload, "prompt")
    model = Map.get(task_payload, "model", "claude-opus-4-6")

    cond do
      is_binary(query) ->
        # Simplified: just echo back the query as a result
        # In production, this would call the LLM service
        {:ok, %{"query" => query, "response" => "Processed: #{String.slice(query, 0, 50)}"}}

      true ->
        {:error, :missing_query}
    end
  end

  # Private: Publish completion back to dispatcher
  defp publish_completion(subtask_id, decomposition_id, status, result) do
    event_data =
      EventBuilder.build_event("dispatcher.subtask.completed", %{
        "subtask_id" => subtask_id,
        "decomposition_id" => decomposition_id,
        "status" => status,
        "result" => result
      })

    case Publisher.publish("dispatcher.subtask.completed", event_data) do
      {:ok, _subject} ->
        Logger.debug("[SubtaskHandler] Published subtask completion",
          subtask_id: subtask_id,
          status: status
        )

      {:error, reason} ->
        Logger.error("[SubtaskHandler] Failed to publish completion: #{inspect(reason)}")
    end
  end
end
