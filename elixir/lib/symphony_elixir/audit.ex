defmodule SymphonyElixir.Audit do
  @moduledoc """
  Append-only public audit record and query boundary.
  """

  import Ecto.Query

  alias SymphonyElixir.Audit.{Event, Redactor}
  alias SymphonyElixir.Effects.OperationId
  alias SymphonyElixir.Repo

  @metadata_keys [
    :target,
    :task_id,
    :configuration_revision,
    :plan_revision,
    :outcome,
    :correlation_id,
    :dedupe_key,
    :payload
  ]

  @semantic_fields [
    :actor,
    :action,
    :target,
    :task_id,
    :configuration_revision,
    :plan_revision,
    :outcome,
    :correlation_id,
    :payload
  ]

  @spec record(atom() | String.t(), map(), term()) ::
          {:ok, Event.t()} | {:error, :dedupe_conflict | Ecto.Changeset.t()}
  def record(action, attrs, actor) when is_map(attrs) do
    attrs = normalize_keys(attrs)
    task_id = Map.get(attrs, :task_id)

    event_attrs = %{
      id: OperationId.generate(),
      actor: actor |> normalize_identity("actor") |> Redactor.redact(),
      action: redact_name(action),
      target: attrs |> Map.get(:target, default_target(task_id)) |> normalize_identity("target") |> Redactor.redact(),
      task_id: redact_optional_string(task_id),
      configuration_revision: attrs |> Map.get(:configuration_revision) |> redact_optional_string(),
      plan_revision: attrs |> Map.get(:plan_revision) |> redact_plan_revision(),
      outcome: attrs |> Map.get(:outcome, :succeeded) |> redact_name(),
      correlation_id: attrs |> Map.get(:correlation_id, task_id || OperationId.generate()) |> redact_name(),
      dedupe_key: attrs |> Map.get(:dedupe_key) |> redact_optional_string(),
      payload: attrs |> payload() |> Redactor.redact() |> normalize_payload()
    }

    insert_result =
      %Event{}
      |> Event.create_changeset(event_attrs)
      |> insert_event(event_attrs)

    resolve_dedupe(insert_result, event_attrs)
  end

  def record(action, _attrs, actor) do
    record(action, %{}, actor)
  end

  @spec get!(Ecto.UUID.t()) :: Event.t()
  def get!(id), do: Repo.get!(Event, id)

  @spec list(keyword() | map()) :: [Event.t()]
  def list(filters \\ []) do
    filters
    |> normalize_filters()
    |> Enum.reduce(Event, &apply_filter/2)
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> Repo.all()
  end

  defp payload(attrs) do
    case Map.fetch(attrs, :payload) do
      {:ok, value} -> value
      :error -> Map.drop(attrs, @metadata_keys)
    end
  end

  defp normalize_payload(value) when is_map(value), do: value
  defp normalize_payload(value), do: %{"summary" => value}

  defp resolve_dedupe({:ok, event}, _event_attrs), do: {:ok, event}

  defp resolve_dedupe({:error, :event_conflict}, %{dedupe_key: dedupe_key} = event_attrs)
       when is_binary(dedupe_key) do
    resolve_existing_dedupe(dedupe_key, event_attrs, :dedupe_conflict)
  end

  defp resolve_dedupe({:error, changeset}, %{dedupe_key: dedupe_key} = event_attrs)
       when is_binary(dedupe_key) do
    resolve_existing_dedupe(dedupe_key, event_attrs, changeset)
  end

  defp resolve_dedupe({:error, changeset}, _event_attrs), do: {:error, changeset}

  defp insert_event(changeset, %{dedupe_key: dedupe_key}) when is_binary(dedupe_key) do
    Repo.insert(changeset)
  rescue
    error in Exqlite.Error ->
      if error.message == "audit events are append-only" do
        {:error, :event_conflict}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp insert_event(changeset, _event_attrs), do: Repo.insert(changeset)

  defp resolve_existing_dedupe(dedupe_key, event_attrs, missing_result) do
    case Repo.get_by(Event, dedupe_key: dedupe_key) do
      %Event{} = existing ->
        if same_semantics?(existing, event_attrs),
          do: {:ok, existing},
          else: {:error, :dedupe_conflict}

      nil ->
        {:error, missing_result}
    end
  end

  defp same_semantics?(event, attrs) do
    event
    |> Map.from_struct()
    |> Map.take(@semantic_fields)
    |> Kernel.==(Map.take(attrs, @semantic_fields))
  end

  defp normalize_identity(%struct{} = value, _kind) when is_atom(struct), do: Map.from_struct(value)
  defp normalize_identity(value, _kind) when is_map(value), do: value
  defp normalize_identity(value, kind) when is_binary(value), do: %{"id" => value, "type" => kind}
  defp normalize_identity(value, kind) when is_atom(value), do: %{"id" => Atom.to_string(value), "type" => kind}
  defp normalize_identity(_value, kind), do: %{"id" => "unknown", "type" => kind}

  defp default_target(nil), do: %{"id" => "system", "type" => "system"}
  defp default_target(task_id), do: %{"id" => task_id, "type" => "task"}

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(_value), do: "invalid"

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: normalize_name(value)

  defp redact_name(value), do: value |> normalize_name() |> Redactor.redact()

  defp redact_optional_string(nil), do: nil
  defp redact_optional_string(value), do: value |> normalize_optional_string() |> Redactor.redact()

  defp redact_plan_revision(nil), do: nil
  defp redact_plan_revision(value) when is_integer(value), do: value
  defp redact_plan_revision(value), do: value |> Redactor.redact() |> normalize_plan_revision()

  defp normalize_plan_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} -> revision
      _error -> value
    end
  end

  defp normalize_plan_revision(value), do: value

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {existing_key(key), value}
      pair -> pair
    end)
  end

  defp existing_key(key) do
    Enum.find(@metadata_keys, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_filters(filters) when is_map(filters), do: Map.to_list(filters)
  defp normalize_filters(filters) when is_list(filters), do: filters
  defp normalize_filters(_filters), do: []

  defp apply_filter({key, value}, query) when key in [:task_id, "task_id"],
    do: where(query, [event], event.task_id == ^value)

  defp apply_filter({key, value}, query) when key in [:action, "action"],
    do: where(query, [event], event.action == ^normalize_name(value))

  defp apply_filter({key, value}, query) when key in [:correlation_id, "correlation_id"],
    do: where(query, [event], event.correlation_id == ^value)

  defp apply_filter({key, value}, query) when key in [:outcome, "outcome"],
    do: where(query, [event], event.outcome == ^normalize_name(value))

  defp apply_filter({key, value}, query) when key in [:dedupe_key, "dedupe_key"],
    do: where(query, [event], event.dedupe_key == ^value)

  defp apply_filter(_filter, query), do: query
end
