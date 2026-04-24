defmodule BotArmyLlm.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    if not Ecto.Migration.column_exists?(:prompts, :tenant_id) do
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

    if not Ecto.Migration.column_exists?(:completions, :tenant_id) do
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

    if not Ecto.Migration.column_exists?(:conversations, :tenant_id) do
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
    if Ecto.Migration.column_exists?(:prompts, :tenant_id) do
      drop_if_exists(index(:prompts, [:tenant_id]))
      drop_if_exists(index(:prompts, [:user_id]))

      alter table(:prompts) do
        remove(:tenant_id)
        remove(:user_id)
      end
    end

    if Ecto.Migration.column_exists?(:completions, :tenant_id) do
      drop_if_exists(index(:completions, [:tenant_id]))
      drop_if_exists(index(:completions, [:user_id]))

      alter table(:completions) do
        remove(:tenant_id)
        remove(:user_id)
      end
    end

    if Ecto.Migration.column_exists?(:conversations, :tenant_id) do
      drop_if_exists(index(:conversations, [:tenant_id]))
      drop_if_exists(index(:conversations, [:user_id]))

      alter table(:conversations) do
        remove(:tenant_id)
        remove(:user_id)
      end
    end
  end
end
