defmodule SymphonyElixir.Audit.Redactor do
  @moduledoc """
  Produces JSON-safe audit/effect data without credentials or complete prompts.
  """

  alias SymphonyElixir.Security.{CredentialBroker, SecretStore}

  @redacted "[REDACTED]"
  @prompt_redacted "[PROMPT REDACTED]"
  @redaction_unavailable "[REDACTION UNAVAILABLE]"
  @unsupported "[UNSUPPORTED VALUE]"
  @max_binary_bytes 2_048
  @sensitive_key ~r/(authorization|cookie|credential|password|secret|token|api[_-]?key)/i

  @prompt_key ~r/(?i:(^|[_-])(prompt|instructions?|messages?)([_-]|$))|[a-z0-9](Prompt|Instructions?|Messages?)([A-Z]|$)/

  @spec redact(term()) :: term()
  def redact(value) do
    value
    |> redact_structure()
    |> redact_registered_secrets()
  end

  @doc """
  Reports whether a string contains registered secret plaintext or a stable reference.

  Secret registry and credential resolution failures are treated as sensitive so callers
  can reject identity-bearing values without persisting a possibly unsafe substitute.
  """
  @spec contains_registered_secret?(term()) :: boolean()
  def contains_registered_secret?(value) do
    with {:ok, references} <- secret_references_result(),
         false <- Enum.any?(references, &contains_reference_or_plaintext?(value, &1)) do
      false
    else
      _unsafe_or_unavailable -> true
    end
  end

  defp redact_structure(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp redact_structure(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp redact_structure(%struct{} = value) when is_atom(struct) do
    value
    |> Map.from_struct()
    |> redact_structure()
  end

  defp redact_structure(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, map_value}, redacted ->
      key = normalize_key(key)

      cond do
        Regex.match?(@sensitive_key, key) ->
          Map.put(redacted, key, @redacted)

        Regex.match?(@prompt_key, key) ->
          redacted
          |> Map.put(key, @prompt_redacted)
          |> Map.put("#{key}_truncated", true)
          |> Map.put("#{key}_bytes", value_size(map_value))

        true ->
          Map.put(redacted, key, redact_structure(map_value))
      end
    end)
  end

  defp redact_structure(value) when is_list(value), do: Enum.map(value, &redact_structure/1)

  defp redact_structure(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> redact_structure()
  end

  defp redact_structure(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp redact_structure(value) when is_binary(value) and byte_size(value) > @max_binary_bytes,
    do: "[TRUNCATED #{byte_size(value)} BYTES]"

  defp redact_structure(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp redact_structure(_value), do: @unsupported

  defp redact_registered_secrets(value) do
    case secret_references_result() do
      {:ok, references} -> redact_with_references(value, references)
      {:error, :secret_registry_unavailable} -> unavailable_redaction(value)
    end
  end

  defp redact_with_references(value, references) do
    Enum.reduce_while(references, value, fn reference, current ->
      case redact_with_reference(current, reference) do
        {:ok, redacted} -> {:cont, redacted}
        {:error, _reason} -> {:halt, unavailable_redaction(value)}
      end
    end)
  end

  defp redact_with_reference(current, reference) do
    quietly(fn ->
      CredentialBroker.with_secret(reference, :audit_redaction, fn plaintext ->
        replace_plaintext(current, plaintext)
      end)
    end)
  end

  defp secret_references_result do
    {:ok, SecretStore.list_references()}
  rescue
    _exception -> {:error, :secret_registry_unavailable}
  end

  defp contains_reference_or_plaintext?(value, %SecretStore.Reference{id: id} = reference) do
    contains_text?(value, id) or contains_plaintext?(value, reference)
  end

  defp contains_plaintext?(value, reference) do
    case quietly(fn -> contains_plaintext_with_broker(value, reference) end) do
      {:ok, contains?} when is_boolean(contains?) -> contains?
      {:error, _reason} -> true
    end
  end

  defp contains_plaintext_with_broker(value, reference) do
    CredentialBroker.with_secret(reference, :sensitive_value_check, fn plaintext ->
      contains_text?(value, plaintext)
    end)
  end

  defp contains_text?(value, plaintext) when is_binary(value),
    do: String.contains?(value, plaintext)

  defp contains_text?(value, plaintext) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_text?(plaintext)

  defp contains_text?(value, plaintext) when is_list(value),
    do: Enum.any?(value, &contains_text?(&1, plaintext))

  defp contains_text?(value, plaintext) when is_map(value) do
    value
    |> plain_map()
    |> Enum.any?(fn {key, map_value} ->
      contains_text?(key, plaintext) or contains_text?(map_value, plaintext)
    end)
  end

  defp contains_text?(_value, _plaintext), do: false

  defp plain_map(%struct{} = value) when is_atom(struct), do: Map.from_struct(value)
  defp plain_map(value), do: value

  defp unavailable_redaction(value) when is_map(value),
    do: %{"redaction_error" => @redaction_unavailable}

  defp unavailable_redaction(_value), do: @redaction_unavailable

  defp quietly(fun) do
    previous_level = Logger.get_process_level(self())
    :ok = Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      restore_logger_level(previous_level)
    end
  end

  defp restore_logger_level(nil), do: Logger.delete_process_level(self())
  defp restore_logger_level(level), do: Logger.put_process_level(self(), level)

  defp replace_plaintext(value, plaintext) when is_binary(value) and byte_size(plaintext) > 0,
    do: String.replace(value, plaintext, replacement_for(plaintext))

  defp replace_plaintext(value, plaintext) when is_list(value),
    do: Enum.map(value, &replace_plaintext(&1, plaintext))

  defp replace_plaintext(value, plaintext) when is_map(value) do
    Map.new(value, fn {key, map_value} ->
      {replace_plaintext(key, plaintext), replace_plaintext(map_value, plaintext)}
    end)
  end

  defp replace_plaintext(value, _plaintext), do: value

  defp replacement_for(plaintext) do
    if String.contains?(@redacted, plaintext), do: "", else: @redacted
  end

  defp normalize_key(value) when is_binary(value), do: value
  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(_value), do: "unsupported_key"

  defp value_size(value) when is_binary(value), do: byte_size(value)
  defp value_size(value), do: value |> :erlang.term_to_binary() |> byte_size()
end
