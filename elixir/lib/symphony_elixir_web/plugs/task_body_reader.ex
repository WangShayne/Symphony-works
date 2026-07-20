defmodule SymphonyElixirWeb.Plugs.TaskBodyReader do
  @moduledoc false

  @task_body_limit 65_536

  @spec read_body(Plug.Conn.t(), Keyword.t()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    Plug.Conn.read_body(conn, task_body_opts(conn, opts))
  end

  defp task_body_opts(%{method: "POST", request_path: "/api/v1/tasks"}, opts) do
    Keyword.merge(opts, length: @task_body_limit, read_length: @task_body_limit)
  end

  defp task_body_opts(_conn, opts), do: opts
end
