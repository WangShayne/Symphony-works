defmodule SymphonyElixir.SourceControl.AdapterSupport do
  @moduledoc false

  alias SymphonyElixir.SourceControl.Transport

  @spec operation_identity(keyword()) ::
          {:ok, String.t(), String.t()} | {:error, :missing_operation_identity}
  def operation_identity(opts) when is_list(opts) do
    operation_id = Keyword.get(opts, :operation_id)
    dedupe_key = Keyword.get(opts, :dedupe_key)

    if nonempty_string?(operation_id) and nonempty_string?(dedupe_key) do
      {:ok, operation_id, dedupe_key}
    else
      {:error, :missing_operation_identity}
    end
  end

  @spec value(map(), atom()) :: term()
  def value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  @spec nonempty_string?(term()) :: boolean()
  def nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  @type operation_marker :: %{
          exact: String.t(),
          replay_prefix: String.t(),
          dedupe_prefix: String.t(),
          operation_token: String.t()
        }

  @spec operation_marker(atom(), String.t(), atom(), String.t(), String.t(), [term()]) ::
          {:ok, operation_marker()} | {:error, :invalid_configuration}
  def operation_marker(provider, repository, action, operation_id, dedupe_key, intent_parts) do
    dedupe_digest = digest([provider, repository, action, dedupe_key])
    intent_digest = digest(intent_parts)
    operation_digest = digest([provider, repository, action, operation_id])

    signature_payload =
      marker_signature_payload(provider, repository, action, dedupe_digest, intent_digest, operation_digest)

    # The facade installs the credential in process scope around the callback;
    # capture prevents Dialyzer from treating that higher-order path as absent.
    sign_marker_payload = Function.capture(Transport, :sign_marker_payload, 1)

    with {:ok, signature} <- sign_marker_payload.(signature_payload) do
      dedupe_prefix = "<!-- symphony:dedupe-sha256=#{dedupe_digest} "
      replay_prefix = dedupe_prefix <> "intent-sha256=#{intent_digest} "
      operation_token = "operation-sha256=#{operation_digest}"
      signature_token = "signature-sha256=#{signature}"

      {:ok,
       %{
         provider: provider,
         repository: repository,
         action: action,
         exact: replay_prefix <> operation_token <> " " <> signature_token <> " -->",
         replay_prefix: replay_prefix,
         dedupe_prefix: dedupe_prefix,
         operation_token: operation_token,
         signature_payload: signature_payload
       }}
    end
  end

  @spec comment_marker(atom(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, operation_marker()} | {:error, :invalid_configuration}
  def comment_marker(provider, repository, parent_external_id, operation_id, dedupe_key, body)
      when is_binary(parent_external_id) and is_binary(body) do
    if nonempty_string?(parent_external_id) and nonempty_string?(body) do
      operation_marker(provider, repository, :comment, operation_id, dedupe_key, [
        parent_external_id,
        body_digest(body)
      ])
    else
      {:error, :invalid_configuration}
    end
  end

  def comment_marker(_provider, _repository, _parent_external_id, _operation_id, _dedupe_key, _body),
    do: {:error, :invalid_configuration}

  @spec marker_decision([map()], String.t(), operation_marker()) ::
          {:ok, {:found, map()} | :create}
          | {:error, :ambiguous_external_state | :idempotency_conflict}
  def marker_decision(items, body_key, marker)
      when is_list(items) and is_binary(body_key) and is_map(marker) do
    case marker_fields(marker.exact) do
      {:ok, expected} ->
        items
        |> marker_match_groups(body_key, marker, expected)
        |> marker_decision_from_matches()

      :error ->
        {:ok, :create}
    end
  end

  @spec marker_decision([map()], String.t(), operation_marker(), [String.t()], String.t()) ::
          {:ok, {:found, map()} | :create}
          | {:error, :ambiguous_external_state | :idempotency_conflict}
  def marker_decision(items, body_key, marker, actor_path, trusted_actor_id)
      when is_list(items) and is_binary(body_key) and is_map(marker) and is_list(actor_path) and
             is_binary(trusted_actor_id) do
    items
    |> Enum.filter(&trusted_actor?(&1, actor_path, trusted_actor_id))
    |> marker_decision(body_key, marker)
  end

  @spec append_marker(String.t(), String.t()) :: String.t()
  def append_marker(body, marker) when is_binary(body) and is_binary(marker) do
    marker <> "\n\n" <> body
  end

  @spec body_digest(String.t()) :: String.t()
  def body_digest(body) when is_binary(body), do: digest([body])

  defp marker_matches(items, body_key, marker, expected, mode) do
    Enum.filter(items, &marker_match?(&1, body_key, marker, expected, mode))
  end

  defp marker_match_groups(items, body_key, marker, expected) do
    operation = marker_matches(items, body_key, marker, expected, :operation)

    %{
      exact: marker_matches(items, body_key, marker, expected, :exact),
      replay: marker_matches(items, body_key, marker, expected, :replay),
      operation_conflict?: Enum.any?(operation, &(not marker_match?(&1, body_key, marker, expected, :exact))),
      dedupe: marker_matches(items, body_key, marker, expected, :dedupe)
    }
  end

  defp marker_decision_from_matches(matches) do
    cond do
      length(matches.exact) > 1 or length(matches.replay) > 1 ->
        {:error, :ambiguous_external_state}

      matches.operation_conflict? ->
        {:error, :idempotency_conflict}

      length(matches.replay) == 1 ->
        {:ok, {:found, hd(matches.replay)}}

      matches.dedupe != [] ->
        {:error, :idempotency_conflict}

      true ->
        {:ok, :create}
    end
  end

  defp marker_body(item, body_key), do: to_string(Map.get(item, body_key) || "")

  defp marker_match?(item, body_key, marker, expected, mode) do
    item
    |> marker_body(body_key)
    |> marker_line()
    |> case do
      {:ok, fields} ->
        valid_signature?(marker, fields) and marker_fields_match?(fields, expected, mode)

      :error ->
        false
    end
  end

  defp marker_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> canonical_marker_line()
    |> case do
      {:ok, line} -> marker_fields(line)
      :error -> :error
    end
  end

  defp canonical_marker_line(lines) do
    case lines do
      [marker, "" | _rest] -> {:ok, marker}
      _other -> :error
    end
  end

  defp marker_fields(line) do
    case Regex.run(
           ~r/\A<!-- symphony:dedupe-sha256=([0-9a-f]{64}) intent-sha256=([0-9a-f]{64}) operation-sha256=([0-9a-f]{64}) signature-sha256=([0-9a-f]{64}) -->\z/,
           line
         ) do
      [^line, dedupe, intent, operation, signature] ->
        {:ok, %{dedupe: dedupe, intent: intent, operation: operation, signature: signature}}

      _no_match ->
        :error
    end
  end

  defp marker_fields_match?(fields, expected, :exact), do: fields == expected

  defp marker_fields_match?(fields, expected, :replay),
    do: fields.dedupe == expected.dedupe and fields.intent == expected.intent

  defp marker_fields_match?(fields, expected, :operation), do: fields.operation == expected.operation

  defp marker_fields_match?(fields, expected, :dedupe), do: fields.dedupe == expected.dedupe

  defp valid_signature?(marker, fields) do
    marker
    |> marker_signature_payload(fields.dedupe, fields.intent, fields.operation)
    |> Transport.valid_marker_signature?(fields.signature)
  end

  defp marker_signature_payload(marker, dedupe, intent, operation) do
    marker_signature_payload(marker.provider, marker.repository, marker.action, dedupe, intent, operation)
  end

  defp marker_signature_payload(provider, repository, action, dedupe, intent, operation) do
    Enum.join(
      [
        "provider=#{provider}",
        "repository=#{repository}",
        "action=#{action}",
        "dedupe=#{dedupe}",
        "intent=#{intent}",
        "operation=#{operation}"
      ],
      "\n"
    )
  end

  defp trusted_actor?(item, actor_path, trusted_actor_id) do
    actor_id = get_in(item, actor_path)

    canonical_actor_id?(trusted_actor_id) and is_integer(actor_id) and actor_id > 0 and
      Integer.to_string(actor_id) == trusted_actor_id
  end

  defp canonical_actor_id?(value), do: Regex.match?(~r/\A[1-9][0-9]*\z/, value)

  defp digest(parts) do
    parts
    |> Enum.map_join("|", fn part ->
      encoded = to_string(part)
      "#{byte_size(encoded)}:#{encoded}"
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
