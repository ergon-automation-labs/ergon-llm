defmodule BotArmyLlm.Handlers.InferenceHandler do
  @moduledoc """
  Handles inference operations for the LLM bot.

  This module processes:
  - `llm.inference.chain` - Multi-step inference pipelines
  - `llm.inference.converse` - Multi-turn conversations
  """

  require Logger
  alias BotArmyLlm.NATS.Publisher
  alias BotArmyLlm.EventBuilder
  alias BotArmyLlm.Inference.{Chain, Conversation}

  @doc """
  Handle chained inference requests.

  Validates the payload and executes a multi-step pipeline where each step's output
  becomes the input for the next step.

  Expected payload structure:
  ```
  {
    "chain_id": optional string,
    "steps": [
      {"prompt": "template with {input}", "model": optional},
      ...
    ],
    "initial_input": string,
    "model": optional string (default "auto")
  }
  ```

  Publishes:
  - `llm.chain.step.completed` after each step
  - `llm.chain.completed` on success
  - `llm.error` on failure
  """
  def handle_chain(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_chain_payload(payload) do
      :ok ->
        process_chain(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid chain payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid chain data", tenant_id, user_id)
    end
  end

  @doc """
  Handle conversation requests.

  Creates a new conversation or appends to an existing one, retrieves the conversation
  history, and generates a response.

  Expected payload structure:
  ```
  {
    "message": string (required),
    "session_id": optional uuid,
    "model": optional string
  }
  ```

  Publishes:
  - `llm.conversation.replied` on success
  - `llm.error` on failure
  """
  def handle_converse(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_converse_payload(payload) do
      :ok ->
        process_converse(payload, event_id, message, tenant_id, user_id)

      {:error, reason} ->
        Logger.warning("Invalid converse payload: #{inspect(reason)}")
        publish_error(event_id, reason, "Invalid converse data", tenant_id, user_id)
    end
  end

  # Private functions

  defp validate_chain_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "steps"),
         :ok <- validate_steps(payload["steps"]) do
      require_field(payload, "initial_input")
    end
  end

  defp validate_chain_payload(_), do: {:error, :invalid_payload}

  defp validate_steps([_ | _] = steps) do
    if Enum.all?(steps, &is_map/1) and
         Enum.all?(steps, &Map.has_key?(&1, "prompt")) do
      :ok
    else
      {:error, :invalid_steps}
    end
  end

  defp validate_steps(_), do: {:error, :invalid_steps}

  defp validate_converse_payload(payload) when is_map(payload) do
    require_field(payload, "message")
  end

  defp validate_converse_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_chain(payload, event_id, _original_message, tenant_id, user_id) do
    chain_id = Map.get(payload, "chain_id", UUID.uuid4())
    steps = payload["steps"]
    initial_input = payload["initial_input"]
    model_override = Map.get(payload, "model")
    metadata = Map.get(payload, "metadata", %{})

    Logger.debug("Starting chain #{chain_id} with #{length(steps)} steps")

    BotArmyLlm.LocalQueueManager.increment()

    case Chain.execute(initial_input, steps, model_override) do
      {:ok, step_results} ->
        BotArmyLlm.LocalQueueManager.decrement()
        
        # Publish step completions based on the results
        Enum.with_index(step_results, fn result, index ->
          step = Enum.at(steps, index)
          publish_step_completed(chain_id, step, result["output"], event_id, tenant_id, user_id)
        end) |> Enum.to_list()

        publish_chain_completed(chain_id, step_results, metadata, event_id, tenant_id, user_id)

      {:error, reason} ->
        BotArmyLlm.LocalQueueManager.decrement()
        Logger.error("Chain #{chain_id} failed: #{inspect(reason)}")
        publish_error(event_id, reason, "Chain execution failed", tenant_id, user_id)
    end
  end

  # Removed legacy private functions moved to domain modules.
  # execute_step, get_or_create_conversation, handle_converse_llm_call are now in BotArmyLlm.Inference.*
  

  defp process_converse(payload, event_id, _original_message, tenant_id, user_id) do
    session_id = Map.get(payload, "session_id")
    user_message = payload["message"]
    model_override = Map.get(payload, "model")

    BotArmyLlm.LocalQueueManager.increment()

    case Conversation.process_turn(session_id, user_message, model_override, tenant_id, user_id) do
      {:ok, %{session_id: final_sid, reply: reply, updated_conversation: conv}} ->
        BotArmyLlm.LocalQueueManager.decrement()
        publish_converse_replied(final_sid, reply, conv, event_id, tenant_id, user_id)

      {:error, reason} ->
        BotArmyLlm.LocalQueueManager.decrement()
        Logger.error("Conversation turn failed: #{inspect(reason)}")
        publish_error(event_id, reason, "LLM inference failed", tenant_id, user_id)
    end
  end

  

  

  

  defp publish_step_completed(chain_id, step, output, triggered_by_event_id, tenant_id, user_id) do
    event_data =
      EventBuilder.build("llm.chain.step.completed", %{
        "chain_id" => chain_id,
        "step_prompt" => String.slice(step["prompt"], 0, 100),
        "step_output" => output,
        "triggered_by_event_id" => triggered_by_event_id,
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case BotArmyLlm.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published chain step completed event")
      {:error, reason} -> Logger.error("Failed to publish step event: #{inspect(reason)}")
    end
  end

  defp publish_chain_completed(
         chain_id,
         step_results,
         metadata,
         triggered_by_event_id,
         tenant_id,
         user_id
       ) do
    event_data =
      EventBuilder.build("llm.chain.completed", %{
        "chain_id" => chain_id,
        "steps" => step_results,
        "total_steps" => length(step_results),
        "metadata" => metadata,
        "triggered_by_event_id" => triggered_by_event_id,
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case BotArmyLlm.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published chain completed event")
      {:error, reason} -> Logger.error("Failed to publish chain event: #{inspect(reason)}")
    end
  end

  defp publish_converse_replied(
         session_id,
         reply,
         conversation,
         triggered_by_event_id,
         tenant_id,
         user_id
       ) do
    event_data =
      EventBuilder.build("llm.conversation.replied", %{
        "session_id" => session_id,
        "reply" => reply,
        "message_count" => length(conversation["messages"] || []),
        "model_used" => conversation["model"],
        "triggered_by_event_id" => triggered_by_event_id,
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case BotArmyLlm.NATS.Publisher.publish(event_data) do
      :ok -> Logger.debug("Published conversation replied event")
      {:error, reason} -> Logger.error("Failed to publish converse event: #{inspect(reason)}")
    end
  end

  defp publish_error(event_id, reason, message, tenant_id, user_id) do
    error_event = %{
      "event" => "llm.error",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    case BotArmyLlm.NATS.Publisher.publish(error_event) do
      :ok -> Logger.debug("Published error event")
      {:error, err} -> Logger.error("Failed to publish error: #{inspect(err)}")
    end
  end
end
