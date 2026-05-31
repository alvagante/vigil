defmodule VigilWeb.Live.Settings.IntegrationsLive do
  @moduledoc """
  Admin LiveView for managing integration instances (design §2.4, §9, issue #5).
  Route: /settings/integrations

  Lists all configured integrations with their enabled/disabled status. Allows
  creating new instances (schema-driven form validated against the plugin's
  declared `config_schema/0`), editing config, and toggling enabled state.
  """

  use VigilWeb, :live_view

  alias Vigil.Core.{Integration, IntegrationConfig}
  alias Vigil.Plugin.{Catalog, Schema}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_lifecycle")

    {:ok,
     socket
     |> assign(:page_title, "Integrations")
     |> assign(:integrations, IntegrationConfig.list_all())
     |> assign(:available_plugins, Catalog.all())
     |> assign(:form_mode, nil)
     |> assign(:editing, nil)
     |> assign(:changeset, nil)
     |> assign(:validation_errors, [])}
  end

  @impl true
  def handle_event("new", _params, socket) do
    changeset = Integration.changeset(%Integration{}, %{})

    {:noreply,
     socket
     |> assign(:form_mode, :new)
     |> assign(:editing, nil)
     |> assign(:changeset, changeset)
     |> assign(:validation_errors, [])}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    integration = IntegrationConfig.get!(id)
    changeset = Integration.changeset(integration, %{})

    {:noreply,
     socket
     |> assign(:form_mode, :edit)
     |> assign(:editing, integration)
     |> assign(:changeset, changeset)
     |> assign(:validation_errors, [])}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:form_mode, nil) |> assign(:editing, nil)}
  end

  def handle_event("save", %{"integration" => params}, socket) do
    plugin_id = params["plugin_id"] || (socket.assigns.editing && socket.assigns.editing.plugin_id)
    config_params = params["config"] || %{}

    with {:ok, schema} <- resolve_schema(plugin_id, socket.assigns.available_plugins),
         {:ok, _config} <- Schema.validate(schema, config_params) do
      result =
        case socket.assigns.form_mode do
          :new -> IntegrationConfig.create(params)
          :edit -> IntegrationConfig.update(socket.assigns.editing, params)
        end

      case result do
        {:ok, _integration} ->
          {:noreply,
           socket
           |> assign(:form_mode, nil)
           |> assign(:editing, nil)
           |> assign(:integrations, IntegrationConfig.list_all())
           |> put_flash(:info, "Integration saved.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :changeset, changeset)}
      end
    else
      {:error, errors} ->
        {:noreply, assign(socket, :validation_errors, errors)}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    case IntegrationConfig.enable(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:integrations, IntegrationConfig.list_all())
         |> put_flash(:info, "Integration enabled.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to enable integration.")}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    case IntegrationConfig.disable(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:integrations, IntegrationConfig.list_all())
         |> put_flash(:info, "Integration disabled.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to disable integration.")}
    end
  end

  @impl true
  def handle_info({event, _id}, socket)
      when event in [:integration_enabled, :integration_disabled, :integration_config_updated] do
    {:noreply, assign(socket, :integrations, IntegrationConfig.list_all())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp resolve_schema(nil, _plugins), do: {:error, [{"plugin_id", "is required"}]}

  defp resolve_schema(plugin_id, plugins) do
    case List.keyfind(plugins, plugin_id, 0) do
      {_id, module} -> {:ok, module.config_schema()}
      nil -> {:ok, %Schema{fields: []}}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <Layouts.flash_group flash={@flash} />
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Integrations</h1>
        <button phx-click="new" class="btn btn-primary">New Integration</button>
      </div>

      <%= if @form_mode do %>
        <div class="card bg-base-200 p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4">
            <%= if @form_mode == :new, do: "New Integration", else: "Edit Integration" %>
          </h2>
          <form phx-submit="save">
            <div class="form-control mb-4">
              <label class="label"><span class="label-text">Plugin</span></label>
              <%= if @form_mode == :new do %>
                <select name="integration[plugin_id]" class="select select-bordered">
                  <option value="">— select plugin —</option>
                  <%= for {plugin_id, _mod} <- @available_plugins do %>
                    <option value={plugin_id}><%= plugin_id %></option>
                  <% end %>
                </select>
              <% else %>
                <input type="text" value={@editing.plugin_id} class="input input-bordered" readonly />
              <% end %>
            </div>
            <div class="form-control mb-4">
              <label class="label"><span class="label-text">Name (slug)</span></label>
              <input
                type="text"
                name="integration[name]"
                value={@editing && @editing.name}
                class="input input-bordered"
                placeholder="my-noop-instance"
              />
            </div>
            <div class="form-control mb-4">
              <label class="label"><span class="label-text">Contract version</span></label>
              <input
                type="text"
                name="integration[contract_version]"
                value={(@editing && @editing.contract_version) || "1.0.0"}
                class="input input-bordered"
              />
            </div>
            <%= if @validation_errors != [] do %>
              <div class="alert alert-error mb-4">
                <ul>
                  <%= for {field, msg} <- @validation_errors do %>
                    <li><strong><%= field %></strong>: <%= msg %></li>
                  <% end %>
                </ul>
              </div>
            <% end %>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary">Save</button>
              <button type="button" phx-click="cancel" class="btn btn-ghost">Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <table class="table w-full">
        <thead>
          <tr>
            <th>Name</th>
            <th>Plugin</th>
            <th>Version</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <%= for integration <- @integrations do %>
            <tr>
              <td><%= integration.name %></td>
              <td><%= integration.plugin_id %></td>
              <td><%= integration.contract_version %></td>
              <td>
                <span class={"badge #{if integration.enabled, do: "badge-success", else: "badge-ghost"}"}>
                  <%= if integration.enabled, do: "enabled", else: "disabled" %>
                </span>
              </td>
              <td class="flex gap-2">
                <button phx-click="edit" phx-value-id={integration.id} class="btn btn-xs btn-ghost">
                  Edit
                </button>
                <%= if integration.enabled do %>
                  <button phx-click="disable" phx-value-id={integration.id} class="btn btn-xs btn-warning">
                    Disable
                  </button>
                <% else %>
                  <button phx-click="enable" phx-value-id={integration.id} class="btn btn-xs btn-success">
                    Enable
                  </button>
                <% end %>
              </td>
            </tr>
          <% end %>
          <%= if @integrations == [] do %>
            <tr>
              <td colspan="5" class="text-center text-base-content/50 py-8">
                No integrations configured. Click "New Integration" to get started.
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
