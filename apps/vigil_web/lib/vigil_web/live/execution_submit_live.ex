defmodule VigilWeb.Live.ExecutionSubmitLive do
  @moduledoc """
  Command submission form — issue #7.
  Route: /executions/new

  Collects command, integration, and target node IDs; calls the plugin-layer
  submit which resolves the runner module and dispatches via Core.Executions.
  Redirects to the execution group's streaming view on success.

  The `principal` is a placeholder until RBAC lands in #8.
  """

  use VigilWeb, :live_view

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Plugin.Executions, as: PluginExecutions

  @impl true
  def mount(_params, _session, socket) do
    integrations = IntegrationConfig.list_all()

    {:ok,
     socket
     |> assign(:page_title, "Run Command")
     |> assign(:integrations, integrations)
     |> assign(:errors, %{})}
  end

  @impl true
  def handle_event("run", %{"execution" => params}, socket) do
    command = String.trim(params["command"] || "")
    integration_id = params["integration_id"] || ""
    node_ids_raw = params["node_ids"] || ""

    errors = validate(command, integration_id, node_ids_raw)

    if errors == %{} do
      node_ids = String.split(node_ids_raw, ~r/[\n,\s]+/, trim: true)
      principal = %{id: "anon"}

      submit_params = %{
        integration_id: integration_id,
        artifact: %{kind: :command, text: command},
        targets: %{node_ids: node_ids}
      }

      case PluginExecutions.submit(principal, submit_params) do
        {:ok, group_id} ->
          {:noreply, push_navigate(socket, to: ~p"/executions/#{group_id}")}

        {:error, reason} ->
          msg = if is_map(reason), do: Map.get(reason, :message, inspect(reason)), else: inspect(reason)
          {:noreply, put_flash(socket, :error, "Submit failed: #{msg}")}
      end
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4 max-w-2xl">
      <Layouts.flash_group flash={@flash} />
      <h1 class="text-2xl font-bold mb-6">Run Command</h1>

      <form id="execution-form" phx-submit="run">
        <div class="form-control mb-4">
          <label class="label"><span class="label-text">Integration</span></label>
          <select name="execution[integration_id]" class="select select-bordered w-full">
            <option value="">— select integration —</option>
            <option :for={i <- @integrations} value={i.id}>
              {i.name} ({i.plugin_id})
            </option>
          </select>
        </div>

        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text">Target nodes (comma or newline separated)</span>
          </label>
          <textarea
            name="execution[node_ids]"
            class="textarea textarea-bordered font-mono"
            rows="3"
            placeholder="web-01, web-02"
          ></textarea>
        </div>

        <div class="form-control mb-4">
          <label class="label"><span class="label-text">command</span></label>
          <input
            type="text"
            name="execution[command]"
            id="execution_command"
            class={"input input-bordered font-mono #{if @errors[:command], do: "input-error"}"}
            placeholder="systemctl status nginx"
          />
          <p :if={@errors[:command]} class="mt-1 text-sm text-error">
            {Map.get(@errors, :command)}
          </p>
        </div>

        <div class="mt-2">
          <button type="submit" class="btn btn-primary">Run</button>
          <.link navigate={~p"/executions"} class="btn btn-ghost ml-2">Cancel</.link>
        </div>
      </form>
    </div>
    """
  end

  defp validate(command, _integration_id, _node_ids) do
    %{}
    |> maybe_add_error(command == "", :command, "can't be blank")
  end

  defp maybe_add_error(errors, false, _field, _msg), do: errors
  defp maybe_add_error(errors, true, field, msg), do: Map.put(errors, field, msg)
end
