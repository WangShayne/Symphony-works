defmodule SymphonyElixirWeb.Configuration.SecretLive do
  @moduledoc """
  Minimal bootstrap Dashboard surface for creating and replacing secrets.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Identity
  alias SymphonyElixir.Identity.Authorization
  alias SymphonyElixir.Security.SecretStore

  @impl true
  def mount(_params, session, socket) do
    case trusted_admin_actor(session, :write_secret) do
      {:ok, actor} -> mount_secrets(socket, actor, trusted_admin_context(session))
      {:error, _reason} -> {:ok, redirect(socket, to: "/auth/login")}
    end
  end

  defp mount_secrets(socket, actor, auth_context) do
    {:ok,
     assign(socket,
       error: nil,
       bind_message: nil,
       reference: nil,
       references: SecretStore.list_references(),
       actor: actor,
       auth_context: auth_context
     )}
  end

  @impl true
  def handle_event("save", %{"secret" => %{"name" => name, "value" => value} = params}, socket) do
    authorize_event(socket, :write_secret, fn actor ->
      result =
        case selected_reference(params) do
          {:ok, nil} ->
            SecretStore.put(name, value, actor: actor)

          {:ok, reference} ->
            SecretStore.replace(reference, value, actor: actor)

          {:error, reason} ->
            {:error, reason}
        end

      case result do
        {:ok, reference} ->
          {:noreply,
           assign(socket,
             reference: reference,
             references: SecretStore.list_references(),
             error: nil,
             actor: actor
           )}

        {:error, _reason} ->
          {:noreply, assign(socket, error: "Secret could not be stored", actor: actor)}
      end
    end)
  end

  def handle_event("save", _params, socket) do
    authorize_event(socket, :write_secret, fn actor ->
      {:noreply, assign(socket, error: "Secret could not be stored", actor: actor)}
    end)
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
    authorize_event(socket, :write_secret, fn actor ->
      result =
        with {:ok, reference} <- SecretStore.reference_for_id(secret_id) do
          Configuration.bind_provider_credential(
            revision_id,
            %{"id" => provider_id, "name" => provider_name},
            SecretStore.export_reference(reference),
            actor: actor
          )
        end

      case result do
        {:ok, _revision} ->
          {:noreply, assign(socket, bind_message: "Provider credential bound", error: nil, actor: actor)}

        {:error, _reason} ->
          {:noreply, assign(socket, error: "Provider credential could not be bound", actor: actor)}
      end
    end)
  end

  def handle_event("bind_provider", _params, socket) do
    authorize_event(socket, :write_secret, fn actor ->
      {:noreply, assign(socket, error: "Provider credential could not be bound", actor: actor)}
    end)
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

  defp authorize_event(socket, action, fun) when is_function(fun, 1) do
    case trusted_admin_actor(socket.assigns.auth_context, action) do
      {:ok, actor} -> fun.(actor)
      {:error, _reason} -> {:noreply, redirect(socket, to: "/auth/login")}
    end
  end

  defp trusted_admin_actor(%{"bootstrap_admin" => true}, _action) do
    if Identity.bootstrap_retired?(), do: {:error, :unauthorized}, else: {:ok, "bootstrap-admin"}
  end

  defp trusted_admin_actor(%{"principal_id" => principal_id}, action) when is_binary(principal_id) do
    case Identity.get_principal(principal_id) do
      {:ok, principal} ->
        case Authorization.authorize(principal, action) do
          :ok -> {:ok, principal.id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trusted_admin_actor(_session, _action), do: {:error, :unauthorized}

  defp trusted_admin_context(%{"bootstrap_admin" => true}), do: %{"bootstrap_admin" => true}
  defp trusted_admin_context(%{"principal_id" => principal_id}) when is_binary(principal_id), do: %{"principal_id" => principal_id}
end
