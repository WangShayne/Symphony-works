import Config

config :phoenix,
  json_library: Jason,
  filter_parameters: ["password", "token", "secret", "credential", "authorization"]

config :symphony_elixir,
  ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixir.Repo,
  journal_mode: :wal,
  busy_timeout: 5_000,
  foreign_keys: :on,
  pool_size: 5

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

import_config "#{config_env()}.exs"
