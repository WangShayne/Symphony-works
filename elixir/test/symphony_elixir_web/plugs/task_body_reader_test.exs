defmodule SymphonyElixirWeb.Plugs.TaskBodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Plug.Parsers.RequestTooLargeError
  alias SymphonyElixirWeb.Plugs.TaskBodyReader

  test "init preserves endpoint parser options" do
    assert TaskBodyReader.init(length: 1, read_length: 1) == [length: 1, read_length: 1]
  end

  test "task create requests reject oversized content-length before body parsing" do
    conn =
      :post
      |> conn("/api/v1/tasks", "")
      |> Plug.Conn.put_req_header("content-length", "65537")

    assert_raise RequestTooLargeError, fn ->
      TaskBodyReader.call(conn, [])
    end
  end

  test "task create requests accept content-length at the limit" do
    conn =
      :post
      |> conn("/api/v1/tasks", "")
      |> Plug.Conn.put_req_header("content-length", "65536")

    assert TaskBodyReader.call(conn, []) == conn
  end

  test "task create requests without content-length continue to body parsing" do
    conn =
      :post
      |> conn("/api/v1/tasks", "")
      |> Plug.Conn.delete_req_header("content-length")

    assert TaskBodyReader.call(conn, []) == conn
  end

  test "task create request path fallback ignores malformed content-length" do
    conn =
      :post
      |> conn("/api/v1/tasks/", "")
      |> Map.put(:path_info, [])
      |> Plug.Conn.put_req_header("content-length", "not-a-number")

    assert TaskBodyReader.call(conn, []) == conn
  end

  test "non task-create requests keep the caller body reader limits" do
    conn = conn(:post, "/api/v1/other", String.duplicate("x", 10))

    assert {:more, "x", _conn} = TaskBodyReader.read_body(conn, length: 1, read_length: 1)
  end

  test "task create body reads use the task body limit" do
    conn = conn(:post, "/api/v1/tasks", String.duplicate("x", 10))

    assert {:ok, body, _conn} = TaskBodyReader.read_body(conn, length: 1, read_length: 1)
    assert body == String.duplicate("x", 10)
  end

  test "non-POST requests bypass task create checks" do
    conn = conn(:get, "/api/v1/tasks")

    assert TaskBodyReader.call(conn, []) == conn
  end
end
