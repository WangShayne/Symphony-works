defmodule SymphonyElixir.Configuration.Exporter do
  @moduledoc """
  Exports configuration revisions with secret-bearing fields redacted.
  """

  alias SymphonyElixir.Configuration.Revision

  @sensitive_key ~r/(api[_-]?key|token|secret|credential|password|authorization)/i

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact(nested)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value), do: value

  @spec export(Revision.t(), keyword()) :: map()
  def export(%Revision{} = revision, opts) do
    redacted? = Keyword.get(opts, :redacted, true)
    document = if redacted?, do: redact(revision.document), else: revision.document

    %{
      "id" => revision.id,
      "status" => Atom.to_string(revision.status),
      "schema_version" => revision.schema_version,
      "content_hash" => revision.content_hash,
      "document" => document
    }
  end

  defp sensitive_key?(key) when is_binary(key), do: Regex.match?(@sensitive_key, key)
  defp sensitive_key?(key), do: key |> to_string() |> sensitive_key?()
end
