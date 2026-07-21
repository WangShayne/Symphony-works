defmodule SymphonyElixir.SourceControl.ChangeRequest do
  @moduledoc """
  Provider-neutral Change Request identity returned by Source Control adapters.
  """

  @enforce_keys [
    :provider,
    :external_id,
    :repository,
    :head_branch,
    :base_branch,
    :draft?,
    :disposition
  ]
  defstruct [
    :provider,
    :external_id,
    :number,
    :url,
    :repository,
    :head_branch,
    :base_branch,
    :title,
    :disposition,
    draft?: true
  ]

  @type t :: %__MODULE__{
          provider: :fixture | :github | :gitlab,
          external_id: String.t(),
          number: non_neg_integer() | nil,
          url: String.t() | nil,
          repository: String.t(),
          head_branch: String.t(),
          base_branch: String.t(),
          title: String.t() | nil,
          draft?: boolean(),
          disposition: :created | :updated | :reconciled
        }
end

defmodule SymphonyElixir.SourceControl.ChangeRequest.State do
  @moduledoc """
  Normalized, read-only delivery state observed from a provider.
  """

  @enforce_keys [
    :provider,
    :external_id,
    :status,
    :base_branch,
    :head_branch,
    :head_sha,
    :base_sha,
    :merge_sha,
    :draft?,
    :ready?,
    :merged?,
    :closed?,
    :required_checks,
    :checks_status,
    :mergeability,
    :observed_at
  ]
  defstruct [
    :provider,
    :external_id,
    :status,
    :base_branch,
    :head_branch,
    :head_sha,
    :base_sha,
    :merge_sha,
    :checks_status,
    :mergeability,
    :observed_at,
    draft?: true,
    ready?: false,
    merged?: false,
    closed?: false,
    required_checks: []
  ]

  @type check_status :: :passed | :pending | :failed | :unknown
  @type required_check :: %{name: String.t(), status: check_status(), url: String.t() | nil}

  @type t :: %__MODULE__{
          provider: :fixture | :github | :gitlab,
          external_id: String.t(),
          status: :open | :closed | :merged,
          base_branch: String.t(),
          head_branch: String.t(),
          head_sha: String.t() | nil,
          base_sha: String.t() | nil,
          merge_sha: String.t() | nil,
          draft?: boolean(),
          ready?: boolean(),
          merged?: boolean(),
          closed?: boolean(),
          required_checks: [required_check()],
          checks_status: :passed | :pending | :failed | :unknown,
          mergeability: :checking | :mergeable | :conflicting | :blocked | :unknown,
          observed_at: DateTime.t()
        }
end
