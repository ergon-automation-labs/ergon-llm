defmodule BotArmyLlm.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    # Add columns to prompts table (use IF NOT EXISTS for idempotence)
    execute("""
      ALTER TABLE prompts
      ADD COLUMN IF NOT EXISTS tenant_id UUID,
      ADD COLUMN IF NOT EXISTS user_id UUID
    """)

    # Create indexes if they don't exist
    execute("""
      CREATE INDEX IF NOT EXISTS prompts_tenant_id_index ON prompts (tenant_id)
    """)

    execute("""
      CREATE INDEX IF NOT EXISTS prompts_user_id_index ON prompts (user_id)
    """)

    # Set default tenant_id for existing rows
    execute("""
      UPDATE prompts SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)

    # Add columns to completions table
    execute("""
      ALTER TABLE completions
      ADD COLUMN IF NOT EXISTS tenant_id UUID,
      ADD COLUMN IF NOT EXISTS user_id UUID
    """)

    execute("""
      CREATE INDEX IF NOT EXISTS completions_tenant_id_index ON completions (tenant_id)
    """)

    execute("""
      CREATE INDEX IF NOT EXISTS completions_user_id_index ON completions (user_id)
    """)

    execute("""
      UPDATE completions SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)

    # Add columns to conversations table
    execute("""
      ALTER TABLE conversations
      ADD COLUMN IF NOT EXISTS tenant_id UUID,
      ADD COLUMN IF NOT EXISTS user_id UUID
    """)

    execute("""
      CREATE INDEX IF NOT EXISTS conversations_tenant_id_index ON conversations (tenant_id)
    """)

    execute("""
      CREATE INDEX IF NOT EXISTS conversations_user_id_index ON conversations (user_id)
    """)

    execute("""
      UPDATE conversations SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS prompts_tenant_id_index")
    execute("DROP INDEX IF EXISTS prompts_user_id_index")
    execute("ALTER TABLE prompts DROP COLUMN IF EXISTS tenant_id")
    execute("ALTER TABLE prompts DROP COLUMN IF EXISTS user_id")

    execute("DROP INDEX IF EXISTS completions_tenant_id_index")
    execute("DROP INDEX IF EXISTS completions_user_id_index")
    execute("ALTER TABLE completions DROP COLUMN IF EXISTS tenant_id")
    execute("ALTER TABLE completions DROP COLUMN IF EXISTS user_id")

    execute("DROP INDEX IF EXISTS conversations_tenant_id_index")
    execute("DROP INDEX IF EXISTS conversations_user_id_index")
    execute("ALTER TABLE conversations DROP COLUMN IF EXISTS tenant_id")
    execute("ALTER TABLE conversations DROP COLUMN IF EXISTS user_id")
  end
end
