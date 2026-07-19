defmodule Mix.Tasks.Secrets.Rotate do
  @moduledoc """
  Rotates encrypted Secret Store rows from one external master key to another.
  """

  use Mix.Task

  alias SymphonyElixir.Security.{MasterKey, SecretStore}

  @shortdoc "Rotate encrypted Secret Store rows"

  @impl true
  @spec run([String.t()]) :: :ok
  def run([]) do
    Mix.Task.run("app.start")

    old_key = read_key!("SYMPHONY_MASTER_KEY")
    new_key = read_key!("SYMPHONY_NEW_MASTER_KEY")

    case SecretStore.rotate(old_key, new_key) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("secret rotation failed: #{format_reason(reason)}")
    end

    Mix.shell().info("Secret Store rotation complete")
  end

  def run(_args) do
    Mix.raise("mix secrets.rotate does not accept key arguments; set SYMPHONY_MASTER_KEY and SYMPHONY_NEW_MASTER_KEY")
  end

  defp read_key!(env_name) do
    case MasterKey.decode(System.get_env(env_name)) do
      {:ok, key} -> key
      {:error, reason} -> Mix.raise("#{env_name} must be a base64-encoded 32-byte key: #{format_reason(reason)}")
    end
  end

  defp format_reason(reason), do: if(is_atom(reason), do: Atom.to_string(reason), else: "error")
end
