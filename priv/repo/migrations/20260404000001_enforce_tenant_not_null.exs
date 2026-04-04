defmodule BotArmyLLM.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration

  def up do
    for table <- [:prompts, :completions, :conversations, :embeddings, :token_usage] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id SET NOT NULL")
    end
  end

  def down do
    for table <- [:prompts, :completions, :conversations, :embeddings, :token_usage] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id DROP NOT NULL")
    end
  end
end
