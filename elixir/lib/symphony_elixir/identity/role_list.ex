defmodule SymphonyElixir.Identity.RoleList do
  @moduledoc false

  use Ecto.Type

  @roles [:viewer, :operator, :administrator]

  @impl true
  def type, do: :text

  @impl true
  def cast(roles) when is_list(roles) do
    roles
    |> Enum.map(&cast_role/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, role}, {:ok, acc} -> {:cont, {:ok, [role | acc]}}
      :error, _acc -> {:halt, :error}
    end)
    |> case do
      {:ok, roles} -> {:ok, roles |> Enum.reverse() |> Enum.uniq()}
      :error -> :error
    end
  end

  def cast(_roles), do: :error

  @impl true
  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, roles} -> cast(roles)
      {:error, _reason} -> :error
    end
  end

  def load(_value), do: :error

  @impl true
  def dump(roles) when is_list(roles) do
    with {:ok, roles} <- cast(roles) do
      {:ok, Jason.encode!(Enum.map(roles, &Atom.to_string/1))}
    end
  end

  def dump(_roles), do: :error

  defp cast_role(role) when role in @roles, do: {:ok, role}

  defp cast_role(role) when is_binary(role) do
    role
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
    |> then(fn atom -> if atom in @roles, do: {:ok, atom}, else: :error end)
  rescue
    ArgumentError -> :error
  end

  defp cast_role(_role), do: :error
end
