ExUnit.start()

Ecto.Migrator.run(
  SymphonyElixir.Repo,
  Application.app_dir(:symphony_elixir, "priv/repo/migrations"),
  :up,
  all: true
)

Ecto.Adapters.SQL.Sandbox.mode(SymphonyElixir.Repo, :manual)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
