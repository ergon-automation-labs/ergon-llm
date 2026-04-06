defmodule BotArmyLlm.Schemas.TokenUsage do
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id

  schema "token_usage" do
    field :event_id, :string
    field :event_type, :string
    field :source, :string
    field :provider, :string
    field :model, :string
    field :tokens_input, :integer
    field :tokens_output, :integer
    field :estimated_cost_usd, :float
    field :latency_ms, :integer
    field :tenant_id, :binary_id
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [
      :event_id,
      :event_type,
      :source,
      :provider,
      :model,
      :tokens_input,
      :tokens_output,
      :estimated_cost_usd,
      :latency_ms,
      :tenant_id,
      :user_id
    ])
    |> Ecto.Changeset.validate_required([
      :event_id,
      :event_type,
      :provider,
      :model
    ])
  end
end
