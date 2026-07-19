defmodule SymphonyElixirWeb.Api.V1.PlaceholderController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"resource" => resource}), do: json(conn, %{data: %{resource: resource}})
  def index(conn, _params), do: json(conn, %{data: []})

  @spec accepted(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accepted(conn, _params), do: conn |> put_status(:accepted) |> json(%{data: %{accepted: true}})
end
