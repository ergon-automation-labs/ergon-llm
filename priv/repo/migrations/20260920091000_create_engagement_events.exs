defmodule BotArmyLlm.Repo.Migrations.CreateEngagementEvents do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:engagement_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, :string, null: false)
      add(:user_id, :string, null: false)
      add(:voice_key, :string, null: false)
      add(:emotional_frame, :string, null: false)
      add(:quest_type, :string, null: false)
      add(:event_type, :string, null: false)
      add(:data, :jsonb, default: "{}")

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:engagement_events, [:task_id]))
    create_if_not_exists(index(:engagement_events, [:user_id]))
    create_if_not_exists(index(:engagement_events, [:voice_key]))
    create_if_not_exists(index(:engagement_events, [:event_type]))

    create_if_not_exists(
      index(:engagement_events, [:user_id, :voice_key], name: :engagement_events_user_voice_idx)
    )
  end
end
