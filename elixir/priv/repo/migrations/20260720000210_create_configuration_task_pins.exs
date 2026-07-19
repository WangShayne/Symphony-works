defmodule SymphonyElixir.Repo.Migrations.CreateConfigurationTaskPins do
  use Ecto.Migration

  def change do
    create table(:configuration_task_pins, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:task_id, :string, null: false)
      add(:revision_id, references(:configuration_revisions, type: :binary_id), null: false)
      add(:content_hash, :string, null: false)
      add(:document, :map, null: false)
      add(:pinned_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:configuration_task_pins, [:task_id]))
    create(index(:configuration_task_pins, [:revision_id]))
  end
end
