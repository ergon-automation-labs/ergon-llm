defmodule BotArmyLlm.Schemas.EngagementEvent do
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id

  schema "engagement_events" do
    field(:task_id, :string)
    field(:user_id, :string)
    field(:voice_key, :string)
    field(:emotional_frame, :string)
    field(:quest_type, :string)
    field(:event_type, :string)
    field(:data, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [
      :task_id,
      :user_id,
      :voice_key,
      :emotional_frame,
      :quest_type,
      :event_type,
      :data
    ])
    |> Ecto.Changeset.validate_required([
      :task_id,
      :user_id,
      :voice_key,
      :emotional_frame,
      :quest_type,
      :event_type
    ])
  end
end
