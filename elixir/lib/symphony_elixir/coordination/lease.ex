defmodule SymphonyElixir.Coordination.Lease do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Query

  alias SymphonyElixir.Repo

  @name "orchestrator"
  @primary_key {:name, :string, autogenerate: false}

  schema "coordination_leases" do
    field(:holder_id, :string)
    field(:token, :binary_id)
    field(:ttl_ms, :integer)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec acquire(String.t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def acquire(holder_id, ttl_ms) do
    now = now()
    token = Ecto.UUID.generate()
    expires_at = DateTime.add(now, ttl_ms, :millisecond)

    attrs = %{
      name: @name,
      holder_id: holder_id,
      token: token,
      ttl_ms: ttl_ms,
      heartbeat_at: now,
      expires_at: expires_at,
      inserted_at: now,
      updated_at: now
    }

    Repo.transaction(
      fn ->
        case reclaim_expired(attrs, now) do
          1 -> Repo.get!(__MODULE__, @name)
          0 -> insert_or_observe(attrs)
        end
      end,
      mode: :immediate
    )
  end

  @spec heartbeat(map()) :: :ok | {:error, :lease_lost}
  def heartbeat(%{name: @name, holder_id: holder_id, token: token})
      when is_binary(holder_id) and is_binary(token) do
    now = now()

    Repo.transaction(
      fn ->
        query =
          from(lease in __MODULE__,
            where:
              lease.name == @name and lease.holder_id == ^holder_id and lease.token == ^token and
                lease.expires_at > ^now
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:lease_lost)

          lease ->
            expires_at = DateTime.add(now, lease.ttl_ms, :millisecond)

            {1, _} =
              Repo.update_all(query,
                set: [heartbeat_at: now, expires_at: expires_at, updated_at: now]
              )

            :ok
        end
      end,
      mode: :immediate
    )
    |> unwrap_ok()
  end

  def heartbeat(_lease), do: {:error, :lease_lost}

  @spec release(map()) :: :ok | {:error, :lease_lost}
  def release(%{name: @name, holder_id: holder_id, token: token})
      when is_binary(holder_id) and is_binary(token) do
    query =
      from(lease in __MODULE__,
        where: lease.name == @name and lease.holder_id == ^holder_id and lease.token == ^token
      )

    case Repo.delete_all(query) do
      {1, _} -> :ok
      {0, _} -> {:error, :lease_lost}
    end
  end

  def release(_lease), do: {:error, :lease_lost}

  defp reclaim_expired(attrs, now) do
    query = from(lease in __MODULE__, where: lease.name == @name and lease.expires_at <= ^now)

    {count, _} =
      Repo.update_all(query,
        set: [
          holder_id: attrs.holder_id,
          token: attrs.token,
          ttl_ms: attrs.ttl_ms,
          heartbeat_at: attrs.heartbeat_at,
          expires_at: attrs.expires_at,
          updated_at: attrs.updated_at
        ]
      )

    count
  end

  defp insert_or_observe(attrs) do
    case Repo.insert_all(__MODULE__, [attrs],
           on_conflict: :nothing,
           conflict_target: [:name]
         ) do
      {1, _} ->
        Repo.get!(__MODULE__, @name)

      {0, _} ->
        existing = Repo.get!(__MODULE__, @name)
        Repo.rollback({:owned_by, existing.holder_id})
    end
  end

  defp unwrap_ok({:ok, :ok}), do: :ok
  defp unwrap_ok({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
