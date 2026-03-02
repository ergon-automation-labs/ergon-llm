defmodule BotArmyLlm.Application do
  @moduledoc """
  BotArmyLlm application supervisor.

  Manages LLM bot services:
  - NATS message consumer
  - Prompt processor
  - Inference pipeline
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database connection
      BotArmyLlm.Repo,

      # Prompt storage (in-memory + Ecto persistence)
      {BotArmyLlm.PromptStore, []},

      # NATS connection and consumer
      {BotArmyLlm.NATS.Consumer, []}
    ]

    opts = [strategy: :one_for_one, name: BotArmyLlm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
