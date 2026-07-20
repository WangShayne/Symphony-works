defmodule SymphonyElixir.Configuration do
  @moduledoc """
  Public interface for database-backed configuration revisions.

  Drafts are mutable only through future revision operations. Activation always revalidates
  the complete snapshot and switches the single active pointer in one transaction.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Multi
  alias SymphonyElixir.Configuration.{Document, Exporter, Revision, TaskPin, Templates, Validator}
  alias SymphonyElixir.Configuration.WorkflowImporter
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore

  @spec create_draft(map(), keyword()) :: {:ok, Revision.t()} | {:error, tuple() | Ecto.Changeset.t()}
  def create_draft(document, opts) when is_map(document) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- validate_runtime_credential_references(document) do
      %Revision{}
      |> Revision.draft_changeset(%{
        document: document,
        schema_version: Map.get(document, "schema_version"),
        content_hash: Document.content_hash(document),
        created_by: actor
      })
      |> Repo.insert()
    end
  end

  @spec update_draft(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Revision.t()} | {:error, :not_found | tuple() | Ecto.Changeset.t()}
  def update_draft(id, document, opts) when is_map(document) do
    _actor = Keyword.fetch!(opts, :actor)

    with %Revision{} = revision <- Repo.get(Revision, id),
         :ok <- validate_transition(revision.status, :draft_update),
         :ok <- validate_runtime_credential_references(document) do
      revision
      |> Revision.update_draft_changeset(%{
        document: document,
        schema_version: Map.get(document, "schema_version"),
        content_hash: Document.content_hash(document)
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp validate_runtime_credential_references(document) do
    invalid_reference? =
      ["providers", "model_references"]
      |> Enum.flat_map(fn key ->
        document
        |> Map.get(key, [])
        |> List.wrap()
      end)
      |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "credential_ref")))
      |> Enum.map(&Map.get(&1, "credential_ref"))
      |> Enum.any?(&(not SecretStore.valid_reference_id?(&1)))

    if invalid_reference? do
      {:error,
       {:invalid_credential_ref,
        %{
          "credential_ref" => "[REDACTED]",
          "reason" => "invalid_reference"
        }}}
    else
      :ok
    end
  end

  @spec validate(Ecto.UUID.t(), keyword()) ::
          {:ok, Revision.t()} | {:error, :not_found | tuple() | Ecto.Changeset.t()}
  def validate(id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with %Revision{} = revision <- Repo.get(Revision, id),
         :ok <- validate_transition(revision.status, :validated),
         {:ok, evidence} <- Validator.validate(revision.document, opts) do
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
      Validator.validate(revision.document, opts)
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

  @spec rollback(Ecto.UUID.t(), keyword()) :: {:ok, Revision.t()} | {:error, term()}
  def rollback(id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    timestamp = now()

    new_multi()
    |> Multi.run(:revision, fn repo, _changes -> fetch_revision(repo, id) end)
    |> Multi.run(:transition, fn _repo, %{revision: revision} ->
      case validate_transition(revision.status, :rollback) do
        :ok -> {:ok, :ok}
        {:error, _reason} = error -> error
      end
    end)
    |> Multi.run(:validation, fn _repo, %{revision: revision} ->
      Validator.validate(revision.document, opts)
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

  @spec bind_provider_credential(Ecto.UUID.t(), map(), SecretStore.secret_reference(), keyword()) ::
          {:ok, Revision.t()} | {:error, term()}
  def bind_provider_credential(id, provider, reference, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with %Revision{} = revision <- Repo.get(Revision, id),
         :ok <- validate_transition(revision.status, :draft),
         {:ok, provider} <- normalize_provider(provider),
         {:ok, reference} <- SecretStore.reference_metadata(reference),
         document <- put_provider_credential(revision.document, provider, reference),
         {:ok, document} <- Document.validate(document) do
      revision
      |> change(%{
        document: document,
        content_hash: Document.content_hash(document),
        created_by: revision.created_by || actor
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
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

  @spec pin_for_task(String.t(), keyword()) :: {:ok, TaskPin.t()} | {:error, term()}
  def pin_for_task(task_id, opts) when is_binary(task_id) do
    actor = Keyword.get(opts, :actor, "system")
    revision_id = Keyword.get(opts, :revision_id)

    case Repo.get_by(TaskPin, task_id: task_id) do
      %TaskPin{} = pin ->
        validate_existing_pin(pin, revision_id)

      nil ->
        task_id
        |> insert_task_pin(actor, revision_id)
        |> resolve_pin_insert_race(task_id, revision_id)
    end
  end

  @spec pinned_for_task!(String.t()) :: TaskPin.t()
  def pinned_for_task!(task_id) when is_binary(task_id) do
    Repo.get_by!(TaskPin, task_id: task_id)
  end

  @spec export(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def export(id, opts) do
    case Repo.get(Revision, id) do
      nil -> {:error, :not_found}
      %Revision{} = revision -> {:ok, Exporter.export(revision, opts)}
    end
  end

  @spec import(map(), keyword()) :: {:ok, Revision.t()} | {:error, term()}
  def import(input, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, document} <- WorkflowImporter.import(input) do
      create_draft(document, actor: actor)
    end
  end

  @spec templates() :: map()
  def templates, do: Templates.all()

  defp fetch_revision(repo, id) do
    case repo.get(Revision, id) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  defp insert_task_pin(task_id, actor, revision_id) do
    with {:ok, revision} <- pin_revision(revision_id),
         :ok <- validate_pin_revision_status(revision.status) do
      %TaskPin{}
      |> TaskPin.changeset(%{
        task_id: task_id,
        revision_id: revision.id,
        content_hash: revision.content_hash,
        document: revision.document,
        pinned_by: actor
      })
      |> Repo.insert()
    end
  end

  defp pin_revision(nil), do: active()
  defp pin_revision(revision_id), do: fetch_revision(Repo, revision_id)

  defp validate_pin_revision_status(status) when status in [:active, :superseded], do: :ok
  defp validate_pin_revision_status(status), do: {:error, {:invalid_pin_revision_status, status}}

  defp validate_existing_pin(pin, nil), do: {:ok, pin}
  defp validate_existing_pin(%TaskPin{revision_id: revision_id} = pin, revision_id), do: {:ok, pin}

  defp validate_existing_pin(%TaskPin{revision_id: revision_id}, _requested_revision_id) do
    {:error, {:configuration_pin_conflict, revision_id}}
  end

  defp resolve_pin_insert_race({:ok, _pin} = result, _task_id, _revision_id), do: result

  defp resolve_pin_insert_race({:error, _reason} = error, task_id, revision_id) do
    case Repo.get_by(TaskPin, task_id: task_id) do
      %TaskPin{} = pin -> validate_existing_pin(pin, revision_id)
      nil -> error
    end
  end

  defp validate_transition(:draft, :draft), do: :ok
  defp validate_transition(:draft, :validated), do: :ok
  defp validate_transition(:draft, :draft_update), do: :ok
  defp validate_transition(:superseded, :rollback), do: :ok

  defp validate_transition(current, requested) do
    {:error, {:invalid_transition, current, requested}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp normalize_provider(%{"id" => id, "name" => name}) when is_binary(id) and is_binary(name) do
    id = String.trim(id)
    name = String.trim(name)

    if id != "" and name != "" do
      {:ok, %{"id" => id, "name" => name}}
    else
      {:error, :invalid_provider}
    end
  end

  defp normalize_provider(%{id: id, name: name}), do: normalize_provider(%{"id" => id, "name" => name})
  defp normalize_provider(_provider), do: {:error, :invalid_provider}

  defp put_provider_credential(document, provider, reference) do
    providers = Map.get(document, "providers", [])
    provider = Map.put(provider, "credential_ref", SecretStore.export_reference(reference))

    providers =
      case Enum.split_with(providers, &(Map.get(&1, "id") == provider["id"])) do
        {[], rest} -> rest ++ [provider]
        {[_existing | _duplicates], rest} -> rest ++ [provider]
      end

    Map.put(document, "providers", providers)
  end

  defp new_multi do
    # Avoid expanding MapSet's nested opaque type on Elixir 1.19 / OTP 28.
    # See https://github.com/elixir-lang/elixir/issues/14576.
    factory = &Multi.new/0
    factory.()
  end
end
