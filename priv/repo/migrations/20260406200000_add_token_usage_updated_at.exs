defmodule BotArmyLlm.Repo.Migrations.AddTokenUsageUpdatedAt do
  use Ecto.Migration

  def up do
    alter table(:token_usage) do
      add :updated_at, :utc_datetime, null: true
    end

    execute "UPDATE token_usage SET updated_at = inserted_at WHERE updated_at IS NULL"

    alter table(:token_usage) do
      modify :updated_at, :utc_datetime, null: false
    end
  end

  def down do
    alter table(:token_usage) do
      remove :updated_at
    end
  end
end
