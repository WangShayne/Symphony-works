defmodule SymphonyElixir.Security.CredentialBroker do
  @moduledoc """
  Resolves secret references only inside outbound adapter callbacks.
  """

  alias SymphonyElixir.Security.SecretStore

  @spec with_secret(SecretStore.secret_reference(), atom() | String.t(), (String.t() -> term())) ::
          {:ok, term()} | {:error, term()}
  def with_secret(reference, purpose, fun) when is_function(fun, 1) do
    with :ok <- validate_purpose(purpose),
         {:ok, plaintext} <- fetch_secret(reference),
         {:ok, result} <- call_adapter(fun, plaintext),
         :ok <- reject_plaintext_return(result, plaintext) do
      normalize_callback_result(result)
    end
  end

  def with_secret(_reference, _purpose, _fun), do: {:error, :invalid_callback}

  defp fetch_secret(reference) do
    SecretStore.fetch(reference, log: false)
  rescue
    _exception -> {:error, :not_found}
  end

  defp validate_purpose(purpose) when is_atom(purpose), do: :ok

  defp validate_purpose(purpose) when is_binary(purpose) do
    if String.trim(purpose) == "", do: {:error, :invalid_purpose}, else: :ok
  end

  defp validate_purpose(_purpose), do: {:error, :invalid_purpose}

  defp normalize_callback_result({:ok, value}), do: {:ok, value}
  defp normalize_callback_result({:error, reason}), do: {:error, reason}
  defp normalize_callback_result(value), do: {:ok, value}

  defp call_adapter(fun, plaintext) do
    {:ok, fun.(plaintext)}
  rescue
    _exception -> {:error, :callback_failed}
  catch
    _kind, _reason -> {:error, :callback_failed}
  end

  defp reject_plaintext_return(result, plaintext) do
    if contains_plaintext?(result, plaintext), do: {:error, :plaintext_returned}, else: :ok
  end

  defp contains_plaintext?(value, plaintext) when is_binary(value), do: String.contains?(value, plaintext)

  defp contains_plaintext?(value, plaintext) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> contains_plaintext?(plaintext)
  end

  defp contains_plaintext?(value, plaintext) when is_list(value) do
    Enum.any?(value, &contains_plaintext?(&1, plaintext))
  end

  defp contains_plaintext?(value, plaintext) when is_map(value) do
    value
    |> plain_map()
    |> Enum.any?(fn {key, map_value} ->
      contains_plaintext?(key, plaintext) or contains_plaintext?(map_value, plaintext)
    end)
  end

  defp contains_plaintext?(_value, _plaintext), do: false

  defp plain_map(%struct{} = value) when is_atom(struct), do: Map.from_struct(value)
  defp plain_map(value), do: value
end
