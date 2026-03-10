defmodule BotArmyLlm.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :session_id, :uuid, null: false
      add :messages, {:array, :map}, null: false, default: []
      add :model, :string
      add :status, :string, null: false, default: "active"

      timestamps()
    end

    create unique_index(:conversations, [:session_id])
    create index(:conversations, [:status])
  end
end
