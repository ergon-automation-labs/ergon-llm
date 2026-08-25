defmodule BotArmyLlm.Repo do
  @moduledoc """
  Ecto Repository for the LLM bot.

  Provides database access for prompts and completions with PostgreSQL backend.
  All queries automatically pass through the database circuit breaker to prevent
  hammering the database during outages.
  """

  use BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo,
    otp_app: :bot_army_llm,
    adapter: Ecto.Adapters.Postgres
end
