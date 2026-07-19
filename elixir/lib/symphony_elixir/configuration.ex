defmodule SymphonyElixir.Configuration do
  @moduledoc """
  Public interface for database-backed configuration revisions.

  Drafts are mutable only through future revision operations. Activation always revalidates
  the complete snapshot and switches the single active pointer in one transaction.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SymphonyElixir.Configuration.{Document, Revision, Validator}
  alias SymphonyElixir.Repo

  @spec create_draft(map(), keyword()) :: {:ok, Revision.t()} | {:error, Ecto.Changeset.t()}
  def create_draft(document, opts) when is_map(document) do
    actor = Keyword.fetch!(opts, :actor)

    %Revision{}
    |> Revision.draft_changeset(%{
      document: document,
      schema_version: Map.get(document, "schema_version"),
      content_hash: Document.content_hash(document),
      created_by: actor
    })
    |> Repo.insert()
  end

  @spec validate(Ecto.UUID.t(), keyword()) ::
          {:ok, Revision.t()} | {:error, :not_found | tuple() | Ecto.Changeset.t()}
  def validate(id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with %Revision{} = revision <- Repo.get(Revision, id),
         :ok <- validate_transition(revision.status, :validated),
         {:ok, evidence} <- Validator.validate(revision.document) do
      revision
      |> Revision.validation_changeset(%{
        validated_by: actor,
        validation_evidence: evidence,
        validated_at: now()
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec activate(Ecto.UUID.t(), keyword()) :: {:ok, Revision.t()} | {:error, term()}
  def activate(id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    timestamp = now()

    new_multi()
    |> Multi.run(:revision, fn repo, _changes -> fetch_revision(repo, id) end)
    |> Multi.run(:validation, fn _repo, %{revision: revision} ->
      Validator.validate(revision.document)
    end)
    |> Multi.update_all(
      :supersede_previous,
      from(revision in Revision, where: revision.status == :active and revision.id != ^id),
      set: [status: :superseded, updated_at: timestamp]
    )
    |> Multi.run(:activate, fn repo, %{revision: revision, validation: evidence} ->
      revision
      |> Revision.activation_changeset(%{
        validated_by: actor,
        validation_evidence: evidence,
        validated_at: timestamp,
        activated_by: actor,
        activated_at: timestamp
      })
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{activate: revision}} -> {:ok, revision}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec active() :: {:ok, Revision.t()} | {:error, :not_found}
  def active do
    case Repo.one(from(revision in Revision, where: revision.status == :active)) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  @spec active!() :: Revision.t()
  def active! do
    Repo.one!(from(revision in Revision, where: revision.status == :active))
  end

  defp fetch_revision(repo, id) do
    case repo.get(Revision, id) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  defp validate_transition(:draft, :validated), do: :ok

  defp validate_transition(current, requested) do
    {:error, {:invalid_transition, current, requested}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp new_multi do
    # Avoid expanding MapSet's nested opaque type on Elixir 1.19 / OTP 28.
    # See https://github.com/elixir-lang/elixir/issues/14576.
    factory = &Multi.new/0
    factory.()
  end
end
