defmodule BotArmyLlm.Inference.Chain do
  @moduledoc """
  Authoritative domain logic for multi-step LLM inference chains.
  """

  require Logger

  @doc """
  Execute a multi-step inference chain.
  Returns {:ok, step_results} or {:error, reason}.
  """
  def execute(initial_input, steps, model_override \\ nil) do
    Logger.debug("Executing inference chain with #{length(steps)} steps")

    result =
      Enum.reduce_while(steps, {:ok, initial_input, []}, fn step, {:ok, input, step_results} ->
        case execute_step(input, step, model_override) do
          {:ok, output} ->
            step_result = %{
              "name" => Map.get(step, "name", "step_#{length(step_results) + 1}"),
              "output" => output
            }
            {:cont, {:ok, output, step_results ++ [step_result]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, _final_output, step_results} -> {:ok, step_results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_step(input, step, model_override) do
    prompt_template = step["prompt"]
    model = model_override || Map.get(step, "model", "auto")
    prompt = String.replace(prompt_template, "{input}", input)

    llm_client = Application.get_env(:bot_army_llm, :llm_client, BotArmyLlm.LlmClient)

    # Queue management is a transport/infrastructure concern, 
    # but we'll leave the call here for now and move queueing to the handler.
    case llm_client.complete(prompt, model: model) do
      {:ok, result} -> {:ok, result.completion}
      {:error, reason} -> {:error, reason}
    end
  end
end
