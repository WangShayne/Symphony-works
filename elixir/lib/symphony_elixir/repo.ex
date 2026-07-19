defmodule SymphonyElixir.Repo do
  @moduledoc """
  Owns Symphony's authoritative SQLite database.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config
    |> Keyword.fetch!(:database)
    |> Path.dirname()
    |> File.mkdir_p!()

    {:ok, config}
  end
end
