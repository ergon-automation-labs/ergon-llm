defmodule BotArmyLlm.Repo.Migrations.CreateTokenUsage do
  use Ecto.Migration

  def change do
    create table(:token_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :source, :string
      add :provider, :string, null: false
      add :model, :string, null: false
      add :tokens_input, :integer
      add :tokens_output, :integer
      add :estimated_cost_usd, :float

      add :latency_ms, :integer

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:token_usage, [:inserted_at])
    create index(:token_usage, [:source])
    create index(:token_usage, [:provider])
  end
end
