import Config

partition = System.get_env("MIX_TEST_PARTITION") || "1"

config :symphony_elixir,
  env: :test,
  auth: [mode: :test],
  workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
  bootstrap_token: "test-bootstrap-token-with-32-bytes",
  master_key_base64: Base.encode64(:binary.copy(<<1>>, 32))

config :symphony_elixir, SymphonyElixir.Repo,
  database: Path.join(System.tmp_dir!(), "symphony_test_#{partition}.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :symphony_elixir, :orchestrator_lifecycle_enabled, false
