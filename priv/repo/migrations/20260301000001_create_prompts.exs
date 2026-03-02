defmodule BotArmyLlm.Repo.Migrations.CreatePrompts do
  use Ecto.Migration

  def change do
    create table(:prompts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :text, :text, null: false
      add :model, :string, null: false
      add :temperature, :float, default: 0.7, null: false
      add :max_tokens, :integer
      add :status, :string, default: "active", null: false

      timestamps()
    end

    create index(:prompts, [:status])
    create index(:prompts, [:model])
  end
end
