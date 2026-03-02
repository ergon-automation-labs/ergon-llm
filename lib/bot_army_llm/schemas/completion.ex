defmodule BotArmyLlm.Schemas.Completion do
  @moduledoc """
  Ecto schema for LLM completions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "completions" do
    field :completion_text, :string
    field :model_used, :string
    field :tokens_input, :integer
    field :tokens_output, :integer

    belongs_to :prompt, BotArmyLlm.Schemas.Prompt

    timestamps()
  end

  @doc false
  def changeset(completion, attrs) do
    completion
    |> cast(attrs, [:completion_text, :model_used, :tokens_input, :tokens_output, :prompt_id])
    |> validate_required([:completion_text, :model_used, :prompt_id])
    |> validate_number(:tokens_input, greater_than_or_equal_to: 0)
    |> validate_number(:tokens_output, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:prompt_id)
  end
end
