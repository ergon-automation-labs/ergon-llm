defmodule BotArmyLlm.Test.JobBellPublisher do
  @moduledoc """
  A publisher that collects events instead of sending them.

  Installed in `test_helper.exs` for the whole suite so no test ever reaches for a
  broker that is not there (a bell that cannot be rung is a warning, and a suite
  that prints one per job teaches people to ignore warnings). A test that wants to
  *assert* on a bell points `:job_bell_sink` at its own pid and receives
  `{:bell_published, event}`.
  """

  @doc """
  Records one event for the current sink. Returns `:ok`, like the real publisher.
  """
  def publish(event) do
    case Application.get_env(:bot_army_llm, :job_bell_sink) do
      pid when is_pid(pid) -> send(pid, {:bell_published, event})
      _ -> :ok
    end

    :ok
  end
end
