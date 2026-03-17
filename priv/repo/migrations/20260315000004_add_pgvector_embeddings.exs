defmodule BotArmyLlm.Repo.Migrations.AddPgvectorEmbeddings do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:embeddings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :document_id, :string, null: false
      add :document_type, :string, null: false
      add :source, :string, null: false
      add :content, :text, null: false
      add :embedding, :vector, size: 768, null: false
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    create index(:embeddings, [:document_id])
    create index(:embeddings, [:document_type])
    create index(:embeddings, [:source])
    execute "CREATE INDEX ON embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"
  end

  def down do
    drop index(:embeddings, [:source])
    drop index(:embeddings, [:document_type])
    drop index(:embeddings, [:document_id])
    drop table(:embeddings)
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
