defmodule SymphonyElixir.Repo.Migrations.CreateSystemMetadata do
  use Ecto.Migration

  def change do
    create table(:system_metadata, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :map, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
