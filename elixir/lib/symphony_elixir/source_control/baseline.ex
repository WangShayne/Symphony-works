defmodule SymphonyElixir.SourceControl.Baseline do
  @moduledoc """
  Immutable target-branch commit observed when a tracked task starts.
  """

  @enforce_keys [:provider, :repository, :branch, :commit_sha]
  defstruct [:provider, :repository, :branch, :commit_sha]

  @type t :: %__MODULE__{
          provider: :fixture | :github | :gitlab,
          repository: String.t(),
          branch: String.t(),
          commit_sha: String.t()
        }
end
