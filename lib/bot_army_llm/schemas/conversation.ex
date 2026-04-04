defmodule BotArmyLlm.Schemas.Conversation do
  @moduledoc """
  Ecto schema for LLM conversations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "conversations" do
    field :session_id, Ecto.UUID
    field :messages, {:array, :map}, default: []
    field :model, :string
    field :status, :string, default: "active"
    field :tenant_id, :binary_id
    field :user_id, :binary_id

    timestamps()
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:session_id, :messages, :model, :status, :tenant_id, :user_id])
    |> validate_required([:session_id, :status])
    |> validate_inclusion(:status, ["active", "archived"])
  end
end
