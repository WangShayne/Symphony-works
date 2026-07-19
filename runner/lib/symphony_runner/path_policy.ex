defmodule SymphonyRunner.PathPolicy do
  @moduledoc """
  Path boundary predicates shared by Runner protocol and policy validation.
  """

  @spec safe_mount_source?(String.t()) :: boolean()
  def safe_mount_source?(source) when is_binary(source) do
    root = safe_mount_source_root()
    expanded = Path.expand(source)

    clean_absolute_path?(source) and under_root?(expanded, root) and
      no_symlink_escape?(expanded, root)
  end

  def safe_mount_source?(_source), do: false

  @spec workspace_path?(String.t()) :: boolean()
  def workspace_path?(path) when is_binary(path) do
    clean_absolute_path?(path) and under_root?(Path.expand(path), "/workspace")
  end

  def workspace_path?(_path), do: false

  @spec writable_workspace_path?(String.t()) :: boolean()
  def writable_workspace_path?(path) when is_binary(path) do
    clean_absolute_path?(path) and under_root?(Path.expand(path), "/workspace/writable")
  end

  def writable_workspace_path?(_path), do: false

  defp safe_mount_source_root do
    :symphony_runner
    |> Application.get_env(:safe_mount_source_root, "/safe")
    |> Path.expand()
  end

  defp under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp clean_absolute_path?(path) do
    String.starts_with?(path, "/") and
      path
      |> String.split("/")
      |> Enum.drop(1)
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp no_symlink_escape?(path, root) do
    path
    |> path_ancestors(root)
    |> Enum.all?(fn candidate ->
      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          candidate |> symlink_target() |> under_root?(root)

        {:ok, _stat} ->
          true

        {:error, _reason} ->
          true
      end
    end)
  end

  defp path_ancestors(path, root) do
    relative =
      path
      |> Path.relative_to(root)
      |> Path.split()

    relative
    |> Enum.scan(root, &Path.join(&2, &1))
    |> then(&[root | &1])
  end

  defp symlink_target(path) do
    {:ok, target} = File.read_link(path)
    Path.expand(target, Path.dirname(path))
  end
end
