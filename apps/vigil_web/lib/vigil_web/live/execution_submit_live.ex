defmodule VigilWeb.Live.ExecutionSubmitLive do
  @moduledoc """
  Command/task/plan submission form — issues #7 and #14.
  Route: /executions/new

  Supports three artifact kinds:
  - command — plain text command (as before)
  - task    — Bolt task with auto-generated parameter form (BOLT-203)
  - plan    — Bolt plan with parameter form

  The `principal` is resolved from session / current_user.
  """

  use VigilWeb, :live_view

  alias Vigil.Core.IntegrationConfig
  alias Vigil.Integrations.Bolt
  alias Vigil.Integrations.Bolt.TypeParser
  alias Vigil.Plugin.Executions, as: PluginExecutions

  @impl true
  def mount(_params, _session, socket) do
    integrations = IntegrationConfig.list_all()

    {:ok,
     socket
     |> assign(:page_title, "Run Command")
     |> assign(:integrations, integrations)
     |> assign(:kind, "command")
     |> assign(:task_list, [])
     |> assign(:plan_list, [])
     |> assign(:task_params, nil)
     |> assign(:plan_params, nil)
     |> assign(:errors, %{})}
  end

  @impl true
  def handle_event("validate", %{"execution" => params}, socket) do
    kind = Map.get(params, "kind", socket.assigns.kind)

    socket =
      socket
      |> assign(:kind, kind)
      |> maybe_load_artifact_list(kind, Map.get(params, "integration_id"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_params", %{"execution" => params}, socket) do
    kind = Map.get(params, "kind", socket.assigns.kind)
    integration_id = Map.get(params, "integration_id", "")
    name = Map.get(params, "task_name") || Map.get(params, "plan_name") || ""

    socket =
      case {kind, integration_id, name} do
        {"task", id, n} when id != "" and n != "" ->
          case Bolt.show_task(id, n, %{}) do
            {:ok, %{data: task}} -> assign(socket, :task_params, task.parameters)
            _ -> socket
          end

        {"plan", id, n} when id != "" and n != "" ->
          case Bolt.show_plan(id, n, %{}) do
            {:ok, %{data: plan}} -> assign(socket, :plan_params, plan.parameters)
            _ -> socket
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("run", %{"execution" => params}, socket) do
    kind = Map.get(params, "kind", "command")
    integration_id = params["integration_id"] || ""
    principal = socket.assigns.current_user

    case build_submit_params(kind, params, integration_id) do
      {:error, errors} ->
        {:noreply, assign(socket, :errors, errors)}

      {:ok, submit_params} ->
        case PluginExecutions.submit(principal, submit_params) do
          {:ok, group_id} ->
            {:noreply, push_navigate(socket, to: ~p"/executions/#{group_id}")}

          {:error, :all_denied} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "The execution is not permitted by your role's policy."
             )}

          {:error, reason} ->
            msg =
              if is_map(reason),
                do: Map.get(reason, :message, inspect(reason)),
                else: inspect(reason)

            {:noreply, put_flash(socket, :error, "Submit failed: #{msg}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4 max-w-2xl">
      <Layouts.flash_group flash={@flash} />
      <h1 class="text-2xl font-bold mb-6">Run Command</h1>

      <form id="execution-form" phx-submit="run" phx-change="validate">
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
          <label class="label"><span class="label-text">Kind</span></label>
          <select name="execution[kind]" class="select select-bordered w-full">
            <option value="command" selected={@kind == "command"}>Command</option>
            <option value="task" selected={@kind == "task"}>Task</option>
            <option value="plan" selected={@kind == "plan"}>Plan</option>
          </select>
        </div>

        <div :if={@kind == "command"} class="form-control mb-4">
          <label class="label"><span class="label-text">Target nodes (comma or newline separated)</span></label>
          <textarea
            name="execution[node_ids]"
            class="textarea textarea-bordered font-mono"
            rows="3"
            placeholder="web-01, web-02"
          ></textarea>
        </div>

        <div :if={@kind == "command"} class="form-control mb-4">
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

        <div :if={@kind == "task"} class="form-control mb-4">
          <label class="label"><span class="label-text">Target nodes (comma or newline separated)</span></label>
          <textarea
            name="execution[node_ids]"
            class="textarea textarea-bordered font-mono"
            rows="3"
            placeholder="web-01, web-02"
          ></textarea>
        </div>

        <div :if={@kind == "task"} class="form-control mb-4">
          <label class="label"><span class="label-text">Task name</span></label>
          <select name="execution[task_name]" id="execution_task_name" class="select select-bordered w-full" phx-change="load_params">
            <option value="">— select task —</option>
            <option :for={t <- @task_list} value={t.name}>{t.name}</option>
          </select>
        </div>

        <div :if={@kind == "plan"} class="form-control mb-4">
          <label class="label"><span class="label-text">Plan name</span></label>
          <select name="execution[plan_name]" id="execution_plan_name" class="select select-bordered w-full" phx-change="load_params">
            <option value="">— select plan —</option>
            <option :for={p <- @plan_list} value={p.name}>{p.name}</option>
          </select>
        </div>

        <div :if={@kind in ["task", "plan"] and @task_params != nil and @kind == "task"}>
          <.param_fields params={@task_params} prefix="task_param" />
        </div>

        <div :if={@kind == "plan" and @plan_params != nil}>
          <.param_fields params={@plan_params} prefix="plan_param" />
        </div>

        <div class="mt-2">
          <button type="submit" class="btn btn-primary">Run</button>
          <.link navigate={~p"/executions"} class="btn btn-ghost ml-2">Cancel</.link>
        </div>
      </form>
    </div>
    """
  end

  defp param_fields(assigns) do
    ~H"""
    <div class="mt-4">
      <h3 class="font-semibold mb-2">Parameters</h3>
      <div :for={p <- @params} class="form-control mb-3">
        <label class="label">
          <span class="label-text">
            {p.name}{if p.required, do: " *", else: ""}
          </span>
          <span :if={p.description} class="label-text-alt text-xs text-gray-500">{p.description}</span>
        </label>
        <.param_widget param={p} prefix={@prefix} />
      </div>
    </div>
    """
  end

  defp param_widget(%{param: %{type: type} = param} = assigns) when is_binary(type) do
    widget_kind = TypeParser.widget_type(type)
    assigns = assign(assigns, :widget_kind, widget_kind)
    assigns = assign(assigns, :enum_values, TypeParser.parse_enum_values(type))

    ~H"""
    <%= if @widget_kind == :boolean do %>
      <input type="checkbox" name={"execution[#{@prefix}][#{@param.name}]"} class="checkbox" value="true" />
    <% else %>
      <%= if @widget_kind == :enum do %>
        <select name={"execution[#{@prefix}][#{@param.name}]"} class="select select-bordered w-full">
          <option value="">— select —</option>
          <option :for={v <- @enum_values} value={v}>{v}</option>
        </select>
      <% else %>
        <input
          type={if @widget_kind == :integer, do: "number", else: "text"}
          name={"execution[#{@prefix}][#{@param.name}]"}
          class="input input-bordered w-full font-mono"
          placeholder={@param.name}
        />
      <% end %>
    <% end %>
    """
  end

  defp maybe_load_artifact_list(socket, "task", integration_id)
       when is_binary(integration_id) and integration_id != "" do
    case Bolt.list_tasks(integration_id, %{}) do
      {:ok, %{data: tasks}} -> assign(socket, :task_list, tasks)
      _ -> socket
    end
  end

  defp maybe_load_artifact_list(socket, "plan", integration_id)
       when is_binary(integration_id) and integration_id != "" do
    case Bolt.list_plans(integration_id, %{}) do
      {:ok, %{data: plans}} -> assign(socket, :plan_list, plans)
      _ -> socket
    end
  end

  defp maybe_load_artifact_list(socket, _kind, _integration_id), do: socket

  defp build_submit_params("command", params, integration_id) do
    command = String.trim(params["command"] || "")
    node_ids_raw = params["node_ids"] || ""

    errors = %{} |> maybe_add_error(command == "", :command, "can't be blank")

    if errors == %{} do
      node_ids = String.split(node_ids_raw, ~r/[\n,\s]+/, trim: true)

      {:ok,
       %{
         integration_id: integration_id,
         artifact: %{kind: :command, text: command},
         targets: %{node_ids: node_ids},
         permission_action: derive_permission(integration_id, "command")
       }}
    else
      {:error, errors}
    end
  end

  defp build_submit_params("task", params, integration_id) do
    task_name = String.trim(params["task_name"] || "")
    node_ids_raw = params["node_ids"] || ""
    task_params = params["task_param"] || %{}

    errors = %{} |> maybe_add_error(task_name == "", :task_name, "select a task")

    if errors == %{} do
      node_ids = String.split(node_ids_raw, ~r/[\n,\s]+/, trim: true)

      {:ok,
       %{
         integration_id: integration_id,
         artifact: %{kind: :task, name: task_name, params: task_params},
         targets: %{node_ids: node_ids},
         permission_action: derive_permission(integration_id, "task")
       }}
    else
      {:error, errors}
    end
  end

  defp build_submit_params("plan", params, integration_id) do
    plan_name = String.trim(params["plan_name"] || "")
    plan_params = params["plan_param"] || %{}

    errors = %{} |> maybe_add_error(plan_name == "", :plan_name, "select a plan")

    if errors == %{} do
      {:ok,
       %{
         integration_id: integration_id,
         artifact: %{kind: :plan, name: plan_name, params: plan_params},
         targets: %{node_ids: ["__plan__"]},
         permission_action: derive_permission(integration_id, "plan")
       }}
    else
      {:error, errors}
    end
  end

  defp derive_permission(integration_id, kind) do
    case Vigil.Repo.get(Vigil.Core.Integration, integration_id) do
      nil -> "#{kind}:execute"
      integration -> "#{integration.plugin_id}:#{kind}:execute"
    end
  end

  defp maybe_add_error(errors, false, _field, _msg), do: errors
  defp maybe_add_error(errors, true, field, msg), do: Map.put(errors, field, msg)
end
