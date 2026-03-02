defmodule BotArmyLlm.Schemas.Prompt do
  @moduledoc """
  Ecto schema for LLM prompts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "prompts" do
    field :text, :string
    field :model, :string
    field :temperature, :float, default: 0.7
    field :max_tokens, :integer
    field :status, :string, default: "active"

    has_many :completions, BotArmyLlm.Schemas.Completion

    timestamps()
  end

  @doc false
  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [:text, :model, :temperature, :max_tokens, :status])
    |> validate_required([:text, :model])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_inclusion(:status, ["active", "archived"])
  end
end
