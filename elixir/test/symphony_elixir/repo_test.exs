defmodule SymphonyElixir.RepoTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Repo

  test "Repo is supervised and SQLite foreign keys are enabled" do
    assert %{rows: [[1]]} = Repo.query!("PRAGMA foreign_keys")
    assert Process.alive?(Process.whereis(Repo))
    assert Repo.__adapter__() == Ecto.Adapters.SQLite3

    test_root =
      Path.join(System.tmp_dir!(), "symphony-init-test-#{System.unique_integer([:positive])}")

    database = Path.join(test_root, "database.db")
    refute File.exists?(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)

    assert {:ok, config} = Repo.init(:supervisor, database: database)
    assert config[:database] == database
    assert File.dir?(Path.dirname(database))
  end
end
