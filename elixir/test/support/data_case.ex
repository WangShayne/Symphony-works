defmodule SymphonyElixir.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias SymphonyElixir.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    owner = Sandbox.start_owner!(SymphonyElixir.Repo, shared: !tags[:async])
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end
end
