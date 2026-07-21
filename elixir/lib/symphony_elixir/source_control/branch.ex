defmodule SymphonyElixir.SourceControl.Branch do
  @moduledoc """
  Normalized remote branch observation.
  """

  @enforce_keys [:provider, :repository, :name, :commit_sha, :disposition]
  defstruct [
    :provider,
    :repository,
    :name,
    :commit_sha,
    :remote_ref,
    :disposition
  ]

  @type t :: %__MODULE__{
          provider: :fixture | :github | :gitlab,
          repository: String.t(),
          name: String.t(),
          commit_sha: String.t(),
          remote_ref: String.t() | nil,
          disposition: :created | :updated | :reconciled
        }
end
