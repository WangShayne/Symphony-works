defmodule SymphonyElixir.Repo.Migrations.CreateConfigurationRevisions do
  use Ecto.Migration

  def change do
    create table(:configuration_revisions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:status, :string, null: false, default: "draft")
      add(:schema_version, :integer, null: false)
      add(:document, :map, null: false)
      add(:content_hash, :string, null: false)
      add(:created_by, :string, null: false)
      add(:validated_by, :string)
      add(:validation_evidence, :map)
      add(:validated_at, :utc_datetime_usec)
      add(:activated_by, :string)
      add(:activated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:configuration_revisions, [:status]))

    create(
      unique_index(:configuration_revisions, [:status],
        where: "status = 'active'",
        name: :configuration_revisions_single_active_index
      )
    )
  end
end
