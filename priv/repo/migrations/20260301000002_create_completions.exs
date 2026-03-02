defmodule BotArmyLlm.Repo.Migrations.CreateCompletions do
  use Ecto.Migration

  def change do
    create table(:completions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :completion_text, :text, null: false
      add :model_used, :string, null: false
      add :tokens_input, :integer
      add :tokens_output, :integer
      add :prompt_id, references(:prompts, type: :uuid, on_delete: :delete_all)

      timestamps()
    end

    create index(:completions, [:prompt_id])
    create index(:completions, [:model_used])
  end
end
