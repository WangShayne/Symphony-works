defmodule SymphonyElixir.Security.SecretStore do
  @moduledoc """
  Public encrypted secret store API.

  Callers receive opaque references. Plaintext is accepted only at write time and
  returned only by `fetch/2` for trusted internal seams and tests.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.{MasterKey, Secret}

  defmodule Reference do
    @moduledoc """
    Opaque reference stored in configuration documents.
    """

    @enforce_keys [:id, :name]
    defstruct [:id, :name]

    @type t :: %__MODULE__{id: Ecto.UUID.t(), name: String.t()}
  end

  @nonce_bytes 12
  @max_secret_bytes 8_192
  @initial_key_version 1

  @type secret_reference :: Reference.t() | map() | Ecto.UUID.t()

  @spec put(String.t(), String.t(), keyword()) :: {:ok, Reference.t()} | {:error, atom() | Ecto.Changeset.t()}
  def put(name, plaintext, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- validate_name(name),
         :ok <- validate_plaintext(plaintext) do
      id = Ecto.UUID.generate()
      key = Keyword.get(opts, :key, current_key!())
      encrypted = encrypt(id, name, plaintext, key, @initial_key_version)

      %Secret{id: id}
      |> Secret.create_changeset(Map.merge(encrypted, %{name: name, created_by: actor, updated_by: actor}))
      |> Repo.insert()
      |> case do
        {:ok, secret} -> {:ok, reference(secret)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @spec replace(secret_reference(), String.t(), keyword()) ::
          {:ok, Reference.t()}
          | {:error,
             :invalid_reference
             | :reference_mismatch
             | :not_found
             | :invalid_secret
             | :decrypt_failed
             | Ecto.Changeset.t()
             | term()}
  def replace(reference, plaintext, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- validate_plaintext(plaintext),
         {:ok, normalized} <- normalize_reference(reference),
         %Secret{} = secret <- Repo.get(Secret, normalized.id),
         :ok <- verify_reference_name(secret, normalized.name) do
      key = Keyword.get(opts, :key, current_key!())
      encrypted = encrypt(secret.id, secret.name, plaintext, key, secret.key_version)

      secret
      |> Secret.replace_changeset(Map.put(encrypted, :updated_by, actor))
      |> Repo.update()
      |> case do
        {:ok, secret} -> {:ok, reference(secret)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch(secret_reference(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :decrypt_failed | :invalid_reference | :reference_mismatch}
  def fetch(reference, opts \\ []) do
    with {:ok, normalized} <- normalize_reference(reference),
         %Secret{} = secret <- Repo.get(Secret, normalized.id),
         :ok <- verify_reference_name(secret, normalized.name),
         key <- Keyword.get(opts, :key, current_key!()),
         {:ok, plaintext} <- decrypt(secret, key) do
      {:ok, plaintext}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec export_reference(secret_reference()) :: Ecto.UUID.t() | nil
  def export_reference(reference) do
    case normalize_reference(reference) do
      {:ok, %{id: id}} -> id
      {:error, _reason} -> nil
    end
  end

  @spec reference_metadata(secret_reference()) ::
          {:ok, map()} | {:error, :not_found | :invalid_reference | :reference_mismatch}
  def reference_metadata(reference) do
    with {:ok, normalized} <- normalize_reference(reference),
         %Secret{} = secret <- Repo.get(Secret, normalized.id),
         :ok <- verify_reference_name(secret, normalized.name) do
      {:ok, %{"id" => secret.id, "name" => secret.name}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reference_for_id(Ecto.UUID.t()) :: {:ok, Reference.t()} | {:error, :not_found}
  def reference_for_id(id) when is_binary(id) do
    case Repo.get(Secret, id) do
      %Secret{} = secret -> {:ok, reference(secret)}
      nil -> {:error, :not_found}
    end
  end

  @spec valid_reference_id?(term()) :: boolean()
  def valid_reference_id?(id) when is_binary(id), do: match?({:ok, _uuid}, Ecto.UUID.cast(id))
  def valid_reference_id?(_id), do: false

  @spec list_references() :: [Reference.t()]
  def list_references do
    Secret
    |> order_by([secret], asc: secret.name, asc: secret.id)
    |> Repo.all()
    |> Enum.map(&reference/1)
  end

  @spec rotate!(binary(), binary()) :: :ok
  def rotate!(old_key, new_key) do
    case rotate(old_key, new_key) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "secret rotation failed: #{inspect(reason)}"
    end
  end

  @spec rotate(binary(), binary()) :: :ok | {:error, term()}
  def rotate(old_key, new_key) when byte_size(old_key) == 32 and byte_size(new_key) == 32 do
    new_multi()
    |> Multi.run(:secrets, fn repo, _changes -> {:ok, repo.all(from(secret in Secret, order_by: secret.id))} end)
    |> Multi.run(:rotate, fn repo, %{secrets: secrets} -> rotate_rows(repo, secrets, old_key, new_key) end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def rotate(_old_key, _new_key), do: {:error, :invalid_key}

  @spec current_key!() :: MasterKey.key()
  def current_key!, do: MasterKey.current!()

  @spec reference(Secret.t()) :: Reference.t()
  def reference(%Secret{id: id, name: name}), do: %Reference{id: id, name: name}

  defp rotate_rows(repo, secrets, old_key, new_key) do
    Enum.reduce_while(secrets, {:ok, 0}, fn secret, {:ok, count} ->
      rotate_row(repo, secret, old_key, new_key, count)
    end)
  end

  defp rotate_row(repo, secret, old_key, new_key, count) do
    with {:ok, plaintext} <- decrypt(secret, old_key),
         encrypted <- encrypt(secret.id, secret.name, plaintext, new_key, secret.key_version + 1),
         changeset <- Secret.replace_changeset(secret, Map.put(encrypted, :updated_by, "system:secret-rotation")),
         {:ok, _secret} <- repo.update(changeset) do
      {:cont, {:ok, count + 1}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp encrypt(id, name, plaintext, key, key_version) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    aad = aad(id, name, key_version)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

    %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_version: key_version}
  end

  defp decrypt(%Secret{} = secret, key) when byte_size(key) == 32 do
    aad = aad(secret.id, secret.name, secret.key_version)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           secret.nonce,
           secret.ciphertext,
           aad,
           secret.tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decrypt_failed}
    end
  end

  defp decrypt(_secret, _key), do: {:error, :decrypt_failed}

  defp aad(id, name, key_version), do: "#{id}:#{name}:#{key_version}"

  defp normalize_reference(%Reference{id: id, name: name}) when is_binary(id) and is_binary(name) and name != "" do
    {:ok, %{id: id, name: name}}
  end

  defp normalize_reference(id) when is_binary(id) do
    if valid_reference_id?(id), do: {:ok, %{id: id, name: nil}}, else: {:error, :invalid_reference}
  end

  defp normalize_reference(%{"id" => id, "name" => name}) when is_binary(id) and is_binary(name) and name != "" do
    {:ok, %{id: id, name: name}}
  end

  defp normalize_reference(%{id: id, name: name}) when is_binary(id) and is_binary(name) and name != "" do
    {:ok, %{id: id, name: name}}
  end

  defp normalize_reference(_reference), do: {:error, :invalid_reference}

  defp verify_reference_name(%Secret{}, nil), do: :ok
  defp verify_reference_name(%Secret{name: name}, name), do: :ok
  defp verify_reference_name(%Secret{}, _name), do: {:error, :reference_mismatch}

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      byte_size(trimmed) > 128 -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_plaintext(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :invalid_secret}
      byte_size(value) > @max_secret_bytes -> {:error, :invalid_secret}
      true -> :ok
    end
  end

  defp validate_plaintext(_value), do: {:error, :invalid_secret}

  defp new_multi do
    # Avoid expanding MapSet's nested opaque type on Elixir 1.19 / OTP 28.
    # See https://github.com/elixir-lang/elixir/issues/14576.
    factory = &Multi.new/0
    factory.()
  end
end
