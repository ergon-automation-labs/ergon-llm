defmodule BotArmyLlm.WellKnownIds do
  @moduledoc """
  Reserved UUID strings for deployments without full auth context (HTTP proxy, migrations).

  Canonical **tenant/user rows** for `…0002` / `…0003` live in `bot_army_identity` (migration
  `SeedClaudeCodeHttpIdentity` and `priv/repo/seeds.exs`). Run `identity_bot` migrations (and seeds in dev)
  so Identity matches these defaults.

  | UUID | Use |
  |------|-----|
  | `00000000-0000-0000-0000-000000000001` | Legacy `token_usage` tenant backfill (`AddTenantAndUserId`). |
  | `00000000-0000-0000-0000-000000000002` | Default **tenant** for `source: "claude_code"` HTTP traffic when `tenant_id` is omitted. |
  | `00000000-0000-0000-0000-000000000003` | Default **user** for that traffic — synthetic “Claude Code client” actor in the same tenant. |

  NATS-backed callers should send real `tenant_id` / `user_id`. Override defaults with
  `BOT_ARMY_LLM_CLAUDE_CODE_TENANT_ID` and `BOT_ARMY_LLM_CLAUDE_CODE_USER_ID` (e.g. to align Claude Code
  usage with your primary tenant UUID).
  """

  @legacy_default_tenant "00000000-0000-0000-0000-000000000001"
  @claude_code_default_tenant "00000000-0000-0000-0000-000000000002"
  @claude_code_default_user "00000000-0000-0000-0000-000000000003"

  def legacy_default_tenant, do: @legacy_default_tenant
  def claude_code_default_tenant, do: @claude_code_default_tenant
  def claude_code_default_user, do: @claude_code_default_user
end
