defmodule SymphonyElixir.Repo.Migrations.AddEffectFencingTokens do
  use Ecto.Migration

  def change do
    alter table(:effect_records) do
      add(:fencing_token, :binary_id)
    end

    create(unique_index(:effect_records, [:fencing_token], where: "fencing_token IS NOT NULL"))
  end
end
