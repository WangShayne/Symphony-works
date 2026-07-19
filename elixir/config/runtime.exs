import Config

if config_env() != :test do
  data_root =
    System.get_env("SYMPHONY_DATA_ROOT") ||
      Path.join([System.user_home!(), ".local", "share", "symphony"])

  database_path =
    System.get_env("SYMPHONY_DATABASE_PATH") || Path.join(data_root, "symphony.db")

  config :symphony_elixir, SymphonyElixir.Repo, database: database_path

  master_key_base64 =
    System.get_env("SYMPHONY_MASTER_KEY") ||
      if config_env() == :prod do
        raise "SYMPHONY_MASTER_KEY must be set to a base64-encoded 32-byte key"
      else
        Base.encode64(:crypto.hash(:sha256, "symphony-development-master-key"))
      end

  with {:ok, key} <- Base.decode64(master_key_base64),
       32 <- byte_size(key) do
    :ok
  else
    _invalid_key -> raise "SYMPHONY_MASTER_KEY must be a base64-encoded 32-byte key"
  end

  config :symphony_elixir,
    env: config_env(),
    auth: [mode: :oidc],
    bootstrap_token: System.get_env("SYMPHONY_BOOTSTRAP_TOKEN"),
    master_key_base64: master_key_base64
end
