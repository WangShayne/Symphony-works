defmodule SymphonyElixirWeb.Auth.BootstrapPlugTest do
  use ExUnit.Case, async: false

  alias SymphonyElixirWeb.Auth.BootstrapPlug

  test "init/1 returns plug options unchanged" do
    opts = [mode: :bootstrap]

    assert BootstrapPlug.init(opts) == opts
  end

  test "bootstrap configuration requires a token with at least 32 bytes" do
    previous_token = Application.get_env(:symphony_elixir, :bootstrap_token)

    on_exit(fn -> Application.put_env(:symphony_elixir, :bootstrap_token, previous_token) end)

    assert :ok = BootstrapPlug.validate_configuration!()

    for token <- [nil, "", "too-short"] do
      Application.put_env(:symphony_elixir, :bootstrap_token, token)

      assert_raise ArgumentError, ~r/at least 32 bytes/, fn ->
        BootstrapPlug.validate_configuration!()
      end
    end
  end
end
