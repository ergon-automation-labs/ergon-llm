defmodule BotArmyLlm.ReasoningScaffold do
  @moduledoc """
  Prepends reasoning instructions to prompts for multi-step queries.

  Supports two modes:

  - `:chain_of_thought` — asks the model to think step-by-step before answering.
  - `:react` — asks the model to follow the ReAct pattern
    (Reason → Act → Observe → repeat).

  The scaffold is applied only when explicitly requested via the
  `reasoning_mode` option. Plain prompts are passed through unchanged.
  """

  @chain_of_thought_prefix """
  Think step-by-step before answering. Break the problem into smaller parts, reason through each one, and then provide your final answer. Show your reasoning explicitly.

  ---

  """

  @react_prefix """
  You are following the ReAct (Reason + Act) pattern.

  For each step of this task:
  1. **Thought**: Explain what you need to figure out next.
  2. **Action**: State the concrete action you will take.
  3. **Observation**: Describe what you learn from that action.
  4. Repeat until you reach a final answer.

  Provide your reasoning explicitly, then give the final answer at the end.

  ---

  """

  @doc """
  Wrap a plain-text prompt with reasoning instructions.

  ## Options

    - `:reasoning_mode` — `:chain_of_thought` | `:react` | `nil` (default)

  ## Examples

      iex> BotArmyLlm.ReasoningScaffold.wrap("What is 2+2?", reasoning_mode: :chain_of_thought)
      "Think step-by-step...\\n\\n---\\n\\nWhat is 2+2?"

      iex> BotArmyLlm.ReasoningScaffold.wrap("What is 2+2?", reasoning_mode: nil)
      "What is 2+2?"
  """
  def wrap(prompt, opts \\ []) do
    case Keyword.get(opts, :reasoning_mode) do
      :chain_of_thought -> @chain_of_thought_prefix <> prompt
      :react -> @react_prefix <> prompt
      _ -> prompt
    end
  end

  @doc """
  Inject a system message into a messages list for multi-turn conversations.

  Returns the messages list with a system message prepended (or replaced if
  one already exists).
  """
  def wrap_messages(messages, opts \\ []) when is_list(messages) do
    case Keyword.get(opts, :reasoning_mode) do
      :chain_of_thought -> ensure_system_message(messages, @chain_of_thought_prefix)
      :react -> ensure_system_message(messages, @react_prefix)
      _ -> messages
    end
  end

  defp ensure_system_message(messages, instruction) do
    {system_messages, rest} =
      Enum.split_with(messages, fn
        %{"role" => "system"} -> true
        _ -> false
      end)

    system_content =
      case system_messages do
        [%{"content" => existing} | _] -> instruction <> "\n" <> existing
        _ -> instruction
      end

    [%{"role" => "system", "content" => system_content} | rest]
  end
end
