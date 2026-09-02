defmodule BotArmyLlm.Inference.Conversation do
  @moduledoc """
  Authoritative domain logic for multi-turn LLM conversations.
  """

  require Logger

  @doc """
  Process a conversation turn.
  Returns {:ok, %{session_id: sid, reply: reply, updated_conversation: conv}} or {:error, reason}.
  """
  def process_turn(session_id, user_message, model_override \\ nil, tenant_id \\ nil, user_id \\ nil) do
    conversation_store = Application.get_env(:bot_army_llm, :conversation_store, BotArmyLlm.ConversationStore)
    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    {final_session_id, conversation} = get_or_create_conversation(
      session_id,
      model_override,
      tenant_id,
      user_id,
      conversation_store
    )

    messages = conversation["messages"] ++ [%{"role" => "user", "content" => user_message}]
    
    case llm_client.complete_messages(messages, model: model_override || conversation["model"] || "auto") do
      {:ok, response} ->
        assistant_message = %{"role" => "assistant", "content" => response.completion}

        case conversation_store.append_message(final_session_id, assistant_message) do
          {:ok, updated_conversation} ->
            {:ok, %{session_id: final_session_id, reply: response.completion, updated_conversation: updated_conversation}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_or_create_conversation(nil, model_override, tenant_id, user_id, conversation_store) do
    case conversation_store.create(%{
           "model" => model_override || "auto",
           "tenant_id" => tenant_id,
           "user_id" => user_id
         }) do
      {:ok, sid, conv} -> {sid, conv}
      {:error, _reason} -> {UUID.uuid4(), %{"messages" => [], "model" => model_override || "auto"}}
    end
  end

  defp get_or_create_conversation(sid, model_override, _tenant_id, _user_id, conversation_store) do
    case conversation_store.get_session(sid) do
      {:ok, conv} -> {sid, conv}
      {:error, _reason} -> {sid, %{"messages" => [], "model" => model_override || "auto"}}
    end
  end
end
