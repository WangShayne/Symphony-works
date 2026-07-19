defmodule SymphonyElixirWeb.Api.V1.SecretController do
  @moduledoc """
  Minimal secret create/replace API that returns only opaque references.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Security.SecretStore

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"secret" => %{"name" => name, "value" => value}}) do
    actor = conn.assigns.current_principal.id

    case SecretStore.put(name, value, actor: actor) do
      {:ok, reference} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize(reference)})

      {:error, _reason} ->
        invalid_secret(conn)
    end
  end

  def create(conn, _params), do: invalid_secret(conn)

  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"id" => id, "secret" => %{"value" => value}}) do
    actor = conn.assigns.current_principal.id

    with {:ok, reference} <- SecretStore.reference_for_id(id),
         {:ok, replaced} <- SecretStore.replace(reference, value, actor: actor) do
      json(conn, %{data: serialize(replaced)})
    else
      {:error, :not_found} -> not_found(conn)
      {:error, _reason} -> invalid_secret(conn)
    end
  end

  def replace(conn, _params), do: invalid_secret(conn)

  defp serialize(reference) do
    {:ok, metadata} = SecretStore.reference_metadata(reference)
    metadata
  end

  defp invalid_secret(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_secret", message: "Secret could not be stored"}})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Secret reference not found"}})
  end
end
