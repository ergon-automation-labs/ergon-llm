defmodule LlmProxy.Release do
  @moduledoc """
  Release tasks for the LLM proxy bot.

  Migrations are run via the shared BotArmyLibraryRuntime.Ecto.MigrationRunner:

      /path/to/llm_proxy/bin/llm_proxy eval 'LlmProxy.Release.migrate()'

  Called from Salt during bot deployment, before the bot starts.
  """

  alias BotArmyLibraryRuntime.Ecto.MigrationRunner

  @app :bot_army_llm

  def migrate do
    MigrationRunner.run(
      repo_module: BotArmyLlm.Repo,
      app_module: @app
    )
  end
end
