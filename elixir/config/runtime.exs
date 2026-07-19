import Config

if config_env() != :test do
  data_root =
    System.get_env("SYMPHONY_DATA_ROOT") ||
      Path.join([System.user_home!(), ".local", "share", "symphony"])

  database_path =
    System.get_env("SYMPHONY_DATABASE_PATH") || Path.join(data_root, "symphony.db")

  config :symphony_elixir, SymphonyElixir.Repo, database: database_path

  config :symphony_elixir,
    bootstrap_token: System.get_env("SYMPHONY_BOOTSTRAP_TOKEN")
end
