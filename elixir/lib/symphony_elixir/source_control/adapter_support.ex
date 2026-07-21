defmodule SymphonyElixir.SourceControl.AdapterSupport do
  @moduledoc false

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
          operation_marker()
  def operation_marker(provider, repository, action, operation_id, dedupe_key, intent_parts) do
    dedupe_digest = digest([provider, repository, action, dedupe_key])
    intent_digest = digest(intent_parts)
    operation_digest = digest([provider, repository, action, operation_id])
    dedupe_prefix = "<!-- symphony:dedupe-sha256=#{dedupe_digest} "
    replay_prefix = dedupe_prefix <> "intent-sha256=#{intent_digest} "
    operation_token = "operation-sha256=#{operation_digest}"

    %{
      exact: replay_prefix <> operation_token <> " -->",
      replay_prefix: replay_prefix,
      dedupe_prefix: dedupe_prefix,
      operation_token: operation_token
    }
  end

  @spec marker_decision([map()], String.t(), operation_marker()) ::
          {:ok, {:found, map()} | :create}
          | {:error, :ambiguous_external_state | :idempotency_conflict}
  def marker_decision(items, body_key, marker)
      when is_list(items) and is_binary(body_key) and is_map(marker) do
    exact = marker_matches(items, body_key, marker.exact)
    replay = marker_matches(items, body_key, marker.replay_prefix)
    operation = marker_matches(items, body_key, marker.operation_token)

    cond do
      length(exact) > 1 or length(replay) > 1 ->
        {:error, :ambiguous_external_state}

      Enum.any?(operation, &(not String.contains?(marker_body(&1, body_key), marker.exact))) ->
        {:error, :idempotency_conflict}

      length(replay) == 1 ->
        {:ok, {:found, hd(replay)}}

      marker_matches(items, body_key, marker.dedupe_prefix) != [] ->
        {:error, :idempotency_conflict}

      true ->
        {:ok, :create}
    end
  end

  @spec append_marker(String.t(), String.t()) :: String.t()
  def append_marker(body, marker) when is_binary(body) and is_binary(marker) do
    String.trim_trailing(body) <> "\n\n" <> marker
  end

  @spec body_digest(String.t()) :: String.t()
  def body_digest(body) when is_binary(body), do: digest([body])

  defp marker_matches(items, body_key, token) do
    Enum.filter(items, &String.contains?(marker_body(&1, body_key), token))
  end

  defp marker_body(item, body_key), do: to_string(Map.get(item, body_key) || "")

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
