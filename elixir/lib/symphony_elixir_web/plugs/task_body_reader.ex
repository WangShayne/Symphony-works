defmodule SymphonyElixirWeb.Plugs.TaskBodyReader do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @task_body_limit 65_536

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if task_create_request?(conn) and oversized_content_length?(conn) do
      raise Plug.Parsers.RequestTooLargeError
    else
      conn
    end
  end

  @spec read_body(Plug.Conn.t(), Keyword.t()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    Plug.Conn.read_body(conn, task_body_opts(conn, opts))
  end

  defp task_body_opts(conn, opts) do
    if task_create_request?(conn) do
      Keyword.merge(opts, length: @task_body_limit, read_length: @task_body_limit)
    else
      opts
    end
  end

  defp task_create_request?(%{method: "POST", path_info: ["api", "v1", "tasks"]}), do: true

  defp task_create_request?(%{method: "POST", request_path: request_path}) do
    request_path
    |> String.trim_trailing("/")
    |> Kernel.==("/api/v1/tasks")
  end

  defp task_create_request?(_conn), do: false

  defp oversized_content_length?(conn) do
    case get_req_header(conn, "content-length") do
      [content_length | _] ->
        case Integer.parse(content_length) do
          {length, ""} -> length > @task_body_limit
          _invalid -> false
        end

      [] ->
        false
    end
  end
end
