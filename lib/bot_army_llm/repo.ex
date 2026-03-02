defmodule BotArmyLlm.Repo do
  @moduledoc """
  Ecto Repository for the LLM bot.

  Provides database access for prompts and completions with PostgreSQL backend.
  """

  use Ecto.Repo,
    otp_app: :bot_army_llm,
    adapter: Ecto.Adapters.Postgres
end
