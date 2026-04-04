defmodule BotArmyLlm.Schemas.Embedding do
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id

  schema "embeddings" do
    field :document_id, :string
    field :document_type, :string
    field :source, :string
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :metadata, :map
    field :tenant_id, :binary_id
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [
      :document_id,
      :document_type,
      :source,
      :content,
      :embedding,
      :metadata,
      :tenant_id,
      :user_id
    ])
    |> Ecto.Changeset.validate_required([
      :document_id,
      :document_type,
      :source,
      :content,
      :embedding
    ])
  end
end
