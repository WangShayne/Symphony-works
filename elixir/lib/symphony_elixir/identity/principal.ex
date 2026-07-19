defmodule SymphonyElixir.Identity.Principal do
  @moduledoc """
  Authenticated actor used by browser, API, and navigation authorization.
  """

  @enforce_keys [:id, :roles]
  defstruct [:id, :issuer, :subject, :email, :display_name, roles: [], service?: false, scopes: []]

  @type role :: :viewer | :operator | :administrator
  @type t :: %__MODULE__{
          id: String.t(),
          issuer: String.t() | nil,
          subject: String.t() | nil,
          email: String.t() | nil,
          display_name: String.t() | nil,
          roles: [role()],
          service?: boolean(),
          scopes: [String.t()]
        }
end
