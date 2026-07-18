defmodule BotArmyLlm.VetoRules do
  @moduledoc false

  alias BotArmyLibraryRuntime.Intent.AccumulatedContext

  @doc """
  Veto GTD remind intents during active LLM conversations.
  If the user is actively chatting with the LLM bot, a reminder
  would be disruptive — the conversation itself is serving the user.
  """
  def veto_remind_during_chat(_envelope) do
    case AccumulatedContext.latest("llm", :conversation_active) do
      nil -> false
      entry -> entry.value == true
    end
  end
end
