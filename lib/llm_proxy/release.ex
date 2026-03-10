defmodule LlmProxy.Release do
  @moduledoc """
  Release tasks for the LLM proxy bot.

  Used for running database migrations from a compiled OTP release:

      /path/to/llm_proxy/bin/llm_proxy eval 'LlmProxy.Release.migrate()'
  """

  @app :bot_army_llm

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
