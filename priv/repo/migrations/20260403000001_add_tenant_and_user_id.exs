defmodule BotArmyLLM.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    # prompts table
    alter table(:prompts) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:prompts, [:tenant_id])
    create index(:prompts, [:user_id])

    # completions table
    alter table(:completions) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:completions, [:tenant_id])
    create index(:completions, [:user_id])

    # conversations table
    alter table(:conversations) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:conversations, [:tenant_id])
    create index(:conversations, [:user_id])

    # embeddings table
    alter table(:embeddings) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:embeddings, [:tenant_id])
    create index(:embeddings, [:user_id])

    # token_usage table
    alter table(:token_usage) do
      add :tenant_id, :uuid, null: true
      add :user_id, :uuid, null: true
    end
    create index(:token_usage, [:tenant_id])
    create index(:token_usage, [:user_id])

    # Backfill all rows with default tenant UUID
    default_tenant_id = "00000000-0000-0000-0000-000000000001"
    execute("""
    UPDATE prompts SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE completions SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE conversations SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE embeddings SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
    execute("""
    UPDATE token_usage SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
  end

  def down do
    # prompts table
    drop index(:prompts, [:tenant_id])
    drop index(:prompts, [:user_id])
    alter table(:prompts) do
      remove :tenant_id
      remove :user_id
    end

    # completions table
    drop index(:completions, [:tenant_id])
    drop index(:completions, [:user_id])
    alter table(:completions) do
      remove :tenant_id
      remove :user_id
    end

    # conversations table
    drop index(:conversations, [:tenant_id])
    drop index(:conversations, [:user_id])
    alter table(:conversations) do
      remove :tenant_id
      remove :user_id
    end

    # embeddings table
    drop index(:embeddings, [:tenant_id])
    drop index(:embeddings, [:user_id])
    alter table(:embeddings) do
      remove :tenant_id
      remove :user_id
    end

    # token_usage table
    drop index(:token_usage, [:tenant_id])
    drop index(:token_usage, [:user_id])
    alter table(:token_usage) do
      remove :tenant_id
      remove :user_id
    end
  end
end
