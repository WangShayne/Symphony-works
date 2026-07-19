defmodule SymphonyElixirWeb.Configuration.SecretLive do
  @moduledoc """
  Minimal bootstrap Dashboard surface for creating and replacing secrets.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Security.SecretStore

  @impl true
  def mount(_params, %{"bootstrap_admin" => true}, socket) do
    {:ok,
     assign(socket,
       error: nil,
       bind_message: nil,
       reference: nil,
       references: SecretStore.list_references()
     )}
  end

  @impl true
  def handle_event("save", %{"secret" => %{"name" => name, "value" => value} = params}, socket) do
    result =
      case selected_reference(params) do
        {:ok, nil} ->
          SecretStore.put(name, value, actor: "bootstrap-admin")

        {:ok, reference} ->
          SecretStore.replace(reference, value, actor: "bootstrap-admin")

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:ok, reference} ->
        {:noreply,
         assign(socket,
           reference: reference,
           references: SecretStore.list_references(),
           error: nil
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Secret could not be stored")}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, assign(socket, error: "Secret could not be stored")}
  end

  def handle_event(
        "bind_provider",
        %{
          "binding" => %{
            "revision_id" => revision_id,
            "provider_id" => provider_id,
            "provider_name" => provider_name,
            "secret_id" => secret_id
          }
        },
        socket
      ) do
    result =
      with {:ok, reference} <- SecretStore.reference_for_id(secret_id) do
        Configuration.bind_provider_credential(
          revision_id,
          %{"id" => provider_id, "name" => provider_name},
          SecretStore.export_reference(reference),
          actor: "bootstrap-admin"
        )
      end

    case result do
      {:ok, _revision} ->
        {:noreply, assign(socket, bind_message: "Provider credential bound", error: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Provider credential could not be bound")}
    end
  end

  def handle_event("bind_provider", _params, socket) do
    {:noreply, assign(socket, error: "Provider credential could not be bound")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="configuration-page">
      <header>
        <p>Bootstrap administration</p>
        <h1>Secrets</h1>
      </header>

      <form id="secret-form" phx-submit="save">
        <label>
          Existing secret
          <select name="secret[reference_id]">
            <option value="">Create new secret</option>
            <option :for={reference <- @references} value={reference.id}>
              {reference.name} ({reference.id})
            </option>
          </select>
        </label>
        <label>
          Name
          <input name="secret[name]" value={if @reference, do: @reference.name, else: ""} required />
        </label>
        <label>
          Value
          <input name="secret[value]" type="password" value="" required />
        </label>
        <button type="submit">Save secret</button>
      </form>

      <p :if={@error} role="alert">{@error}</p>
      <p :if={@bind_message} id="provider-bind-result">{@bind_message}</p>

      <section id="existing-secrets">
        <h2>Existing secrets</h2>
        <ul>
          <li :for={reference <- @references} id={"existing-secret-#{reference.id}"}>
            <span>{reference.name}</span>
            <code>{reference.id}</code>
          </li>
        </ul>
      </section>

      <form id="provider-credential-form" phx-submit="bind_provider">
        <label>
          Draft revision
          <input name="binding[revision_id]" required />
        </label>
        <label>
          Provider ID
          <input name="binding[provider_id]" required />
        </label>
        <label>
          Provider name
          <input name="binding[provider_name]" required />
        </label>
        <label>
          Secret reference
          <select name="binding[secret_id]" required>
            <option :for={reference <- @references} value={reference.id}>
              {reference.name} ({reference.id})
            </option>
          </select>
        </label>
        <button type="submit">Bind provider credential</button>
      </form>

      <section :if={@reference} id="secret-reference">
        <h2>Secret reference</h2>
        <p>{@reference.name}</p>
        <p>{@reference.id}</p>
      </section>
    </section>
    """
  end

  defp selected_reference(%{"reference_id" => ""}), do: {:ok, nil}
  defp selected_reference(%{"reference_id" => id}) when is_binary(id), do: SecretStore.reference_for_id(id)
  defp selected_reference(_params), do: {:ok, nil}
end
