defmodule SymphonyElixir.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  def change do
    create table(:secrets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:key_version, :integer, null: false)
      add(:created_by, :string, null: false)
      add(:updated_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:secrets, [:name]))
  end
end
