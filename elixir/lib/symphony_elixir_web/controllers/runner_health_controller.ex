defmodule SymphonyElixirWeb.RunnerHealthController do
  @moduledoc """
  Public Runner readiness and boundary proof endpoint.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Runner

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, Runner.Health.snapshot())
  end
end
