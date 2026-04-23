defmodule BotArmyLlm.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    # Add tenant_id and user_id to prompts (idempotent)
    unless Ecto.Migration.column_exists?(:prompts, :tenant_id) do
      alter table(:prompts) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:prompts, [:tenant_id]))
      create(index(:prompts, [:user_id]))

      execute(
        "UPDATE prompts SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to completions (idempotent)
    unless Ecto.Migration.column_exists?(:completions, :tenant_id) do
      alter table(:completions) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:completions, [:tenant_id]))
      create(index(:completions, [:user_id]))

      execute(
        "UPDATE completions SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to conversations (idempotent)
    unless Ecto.Migration.column_exists?(:conversations, :tenant_id) do
      alter table(:conversations) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:conversations, [:tenant_id]))
      create(index(:conversations, [:user_id]))

      execute(
        "UPDATE conversations SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end
  end

  def down do
    # Drop indexes and columns for prompts
    drop(index(:prompts, [:tenant_id])) if Ecto.Migration.index_exists?(:prompts, [:tenant_id])
    drop(index(:prompts, [:user_id])) if Ecto.Migration.index_exists?(:prompts, [:user_id])

    alter table(:prompts) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:prompts, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:prompts, :user_id)
    end

    # Drop indexes and columns for completions
    drop(index(:completions, [:tenant_id])) if Ecto.Migration.index_exists?(:completions, [:tenant_id])
    drop(index(:completions, [:user_id])) if Ecto.Migration.index_exists?(:completions, [:user_id])

    alter table(:completions) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:completions, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:completions, :user_id)
    end

    # Drop indexes and columns for conversations
    drop(index(:conversations, [:tenant_id])) if Ecto.Migration.index_exists?(:conversations, [:tenant_id])
    drop(index(:conversations, [:user_id])) if Ecto.Migration.index_exists?(:conversations, [:user_id])

    alter table(:conversations) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:conversations, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:conversations, :user_id)
    end
  end
end
