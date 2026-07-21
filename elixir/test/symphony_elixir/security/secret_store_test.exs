defmodule SymphonyElixir.Security.SecretStoreTest do
  use SymphonyElixir.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.{Configuration.Document, Repo}
  alias SymphonyElixir.Security.{Secret, SecretStore}

  @plaintext "super-secret-value"

  test "plaintext never enters SQLite rows, raw database files, inspect output, or exports" do
    {:ok, ref} = SecretStore.put("github-token", @plaintext, actor: "admin-1")
    row = Repo.get!(Secret, ref.id)

    refute row.ciphertext =~ @plaintext
    refute inspect(row) =~ @plaintext
    assert {:ok, @plaintext} = SecretStore.fetch(ref)

    exported = SecretStore.export_reference(ref)
    assert exported == ref.id
    refute Jason.encode!(exported) =~ @plaintext

    assert {:ok, %{rows: rows}} = SQL.query(Repo, "select * from secrets where id = ?", [ref.id])

    refute inspect(rows) =~ @plaintext

    database = Repo.config() |> Keyword.fetch!(:database) |> File.read!()
    refute database =~ @plaintext
  end

  test "replacement keeps the opaque reference stable and removes old plaintext access" do
    {:ok, ref} = SecretStore.put("model-key", "old-value", actor: "admin-1")
    assert {:ok, replaced} = SecretStore.replace(ref, "new-value", actor: "admin-2")

    assert replaced.id == ref.id
    assert replaced.name == ref.name
    assert {:ok, "new-value"} = SecretStore.fetch(ref)

    row = Repo.get!(Secret, ref.id)
    refute inspect(row) =~ "old-value"
    refute inspect(row) =~ "new-value"
  end

  test "rotation re-encrypts every secret without changing references" do
    old_key = SecretStore.current_key!()
    new_key = :crypto.strong_rand_bytes(32)

    {:ok, first} = SecretStore.put("model-key", "first-value", actor: "admin-1")
    {:ok, second} = SecretStore.put("github-token", "second-value", actor: "admin-1")

    assert :ok = SecretStore.rotate!(old_key, new_key)
    assert {:ok, "first-value"} = SecretStore.fetch(first, key: new_key)
    assert {:ok, "second-value"} = SecretStore.fetch(second, key: new_key)

    assert Repo.get!(Secret, first.id).id == first.id
    assert Repo.get!(Secret, second.id).id == second.id
  end

  test "rotation failure rolls back all rows and preserves old key readability" do
    old_key = SecretStore.current_key!()
    bad_old_key = :crypto.strong_rand_bytes(32)
    new_key = :crypto.strong_rand_bytes(32)

    {:ok, ref} = SecretStore.put("rollback-token", "rollback-value", actor: "admin-1")
    before_row = Repo.get!(Secret, ref.id)

    assert {:error, :decrypt_failed} = SecretStore.rotate(bad_old_key, new_key)

    after_row = Repo.get!(Secret, ref.id)
    assert after_row.ciphertext == before_row.ciphertext
    assert after_row.key_version == before_row.key_version
    assert {:ok, "rollback-value"} = SecretStore.fetch(ref, key: old_key)
  end

  test "invalid create, fetch, replace, export, and rotation inputs fail closed" do
    assert SecretStore.valid_reference_id?(Ecto.UUID.generate())
    refute SecretStore.valid_reference_id?("plaintext-secret")
    refute SecretStore.valid_reference_id?("1234567890abcdef")
    refute SecretStore.valid_reference_id?("00000000-0000-0000-0000-00000000000z")

    assert {:error, :invalid_name} = SecretStore.put("", "value", actor: "admin-1")
    assert {:error, :invalid_name} = SecretStore.put(String.duplicate("n", 129), "value", actor: "admin-1")
    assert {:error, :invalid_name} = SecretStore.put(:bad_name, "value", actor: "admin-1")
    assert {:error, :invalid_secret} = SecretStore.put("empty", "", actor: "admin-1")
    assert {:error, :invalid_secret} = SecretStore.put("huge", String.duplicate("x", 8_193), actor: "admin-1")
    assert {:error, :invalid_secret} = SecretStore.put("bad", :not_binary, actor: "admin-1")

    assert {:error, changeset} = SecretStore.put("missing-actor", "value", actor: nil)
    refute changeset.valid?

    missing = %SecretStore.Reference{id: Ecto.UUID.generate(), name: "missing"}
    assert {:error, :not_found} = SecretStore.fetch(missing)
    assert {:error, :invalid_reference} = SecretStore.fetch(%{})
    assert SecretStore.export_reference(%{}) == nil

    assert {:ok, ref} = SecretStore.put("replace-errors", "value", actor: "admin-1")
    mismatched = %SecretStore.Reference{id: ref.id, name: "wrong-name"}

    assert {:error, :reference_mismatch} = SecretStore.fetch(mismatched)
    assert {:error, :not_found} = SecretStore.replace(missing, "value", actor: "admin-1")
    assert {:error, :reference_mismatch} = SecretStore.replace(mismatched, "value", actor: "admin-1")
    assert {:error, :invalid_secret} = SecretStore.replace(ref, "", actor: "admin-1")
    assert {:error, changeset} = SecretStore.replace(ref, "value", actor: nil)
    refute changeset.valid?

    assert {:error, :decrypt_failed} = SecretStore.fetch(ref, key: :crypto.strong_rand_bytes(16))
    assert {:error, :invalid_key} = SecretStore.rotate(:crypto.strong_rand_bytes(16), :crypto.strong_rand_bytes(32))

    assert_raise ArgumentError, ~r/secret rotation failed/, fn ->
      SecretStore.rotate!(:crypto.strong_rand_bytes(16), :crypto.strong_rand_bytes(32))
    end

    assert {:ok, "value"} = SecretStore.fetch(%{id: ref.id, name: ref.name})
    assert {:ok, "value"} = SecretStore.fetch(ref.id)
  end

  test "configuration documents accept only opaque secret references" do
    {:ok, ref} = SecretStore.put("provider-token", @plaintext, actor: "admin-1")

    document =
      valid_document()
      |> Map.put("providers", [
        %{
          "id" => "openai",
          "name" => "OpenAI",
          "credential_ref" => SecretStore.export_reference(ref)
        }
      ])

    assert {:ok, ^document} = Document.validate(document)
    refute Jason.encode!(document) =~ @plaintext

    invalid =
      put_in(document, ["providers", Access.at(0), "credential"], @plaintext)

    assert {:error, errors} = Document.validate(invalid)
    assert %{path: ["providers", "0", "credential"], message: "is not supported"} in errors
    refute inspect(errors) =~ @plaintext
  end

  test "configuration document reports malformed provider references without leaking values" do
    document = valid_document()

    assert {:error, [%{path: ["providers"], message: "must be a list"}]} =
             document
             |> Map.put("providers", "bad")
             |> Document.validate()

    assert {:error, errors} =
             document
             |> Map.delete("providers")
             |> Document.validate()

    assert %{path: ["providers"], message: "is required"} in errors

    assert {:error, errors} =
             document
             |> Map.put("providers", ["bad"])
             |> Document.validate()

    assert %{path: ["providers", "0"], message: "must be an object"} in errors

    assert {:error, errors} =
             document
             |> Map.put("providers", [%{"id" => "openai", "credential_ref" => "not-a-secret-reference"}])
             |> Document.validate()

    assert %{path: ["providers", "0", "name"], message: "is required"} in errors
    assert %{path: ["providers", "0", "credential_ref"], message: "must be an opaque secret reference"} in errors

    assert {:error, errors} =
             document
             |> Map.put("providers", [%{"id" => "openai", "name" => "OpenAI", "credential_ref" => "bad"}])
             |> Document.validate()

    assert %{path: ["providers", "0", "credential_ref"], message: "must be an opaque secret reference"} in errors

    assert {:error, errors} =
             document
             |> Map.put("providers", [
               %{
                 "id" => "openai",
                 "name" => "OpenAI",
                 "credential_ref" => %{"id" => "ref", "name" => "provider-token", "value" => @plaintext}
               }
             ])
             |> Document.validate()

    assert %{path: ["providers", "0", "credential_ref"], message: "is required"} in errors
    refute inspect(errors) =~ @plaintext
  end

  defp valid_document do
    Document.for_project(%{
      "id" => "symphony",
      "name" => "Symphony",
      "tracker" => %{"kind" => "github", "scope" => "WangShayne/Symphony-works"},
      "repository" => %{
        "url" => "git@github.com:WangShayne/Symphony-works.git",
        "target_branch" => "main"
      }
    })
  end
end
