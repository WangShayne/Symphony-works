defmodule SymphonyElixir.Security.MasterKeyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Security.MasterKey

  test "decodes only base64-encoded 32-byte keys" do
    key = :crypto.strong_rand_bytes(32)
    encoded = Base.encode64(key)

    assert {:ok, ^key} = MasterKey.decode(encoded)
    assert MasterKey.decode!(encoded) == key
    assert {:error, :missing} = MasterKey.decode(nil)
    assert {:error, :invalid} = MasterKey.decode("not base64")
    assert {:error, :invalid} = MasterKey.decode(Base.encode64("short"))

    assert_raise ArgumentError, ~r/invalid SYMPHONY_MASTER_KEY/, fn ->
      MasterKey.decode!("not base64")
    end
  end
end
