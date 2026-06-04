defmodule VigilWeb.Live.Settings.RolesLive do
  use VigilWeb, :live_view

  alias Vigil.Core.{Accounts, Audit, RBAC}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :roles, RBAC.list_roles())}
  end

  def handle_event("create_role", %{"role" => %{"name" => name}}, socket) do
    admin = socket.assigns.current_user

    case RBAC.create_role(%{name: String.trim(name)}) do
      {:ok, role} ->
        Audit.write_finalized(admin, "rbac.role.create", :success,
          target_kind: "role",
          target_id: role.id,
          params: %{role_name: role.name}
        )

        {:noreply, assign(socket, :roles, RBAC.list_roles())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "grant_permission",
        %{"role_id" => role_id, "permission" => %{"action" => action}},
        socket
      ) do
    role = Enum.find(socket.assigns.roles, &(&1.id == role_id))
    admin = socket.assigns.current_user
    trimmed = String.trim(action)

    case RBAC.grant_permission(role, %{action: trimmed}) do
      {:ok, _} ->
        Audit.write_finalized(admin, "rbac.permission.grant", :success,
          target_kind: "role",
          target_id: role.id,
          params: %{role_name: role.name, permission_action: trimmed}
        )

        {:noreply, assign(socket, :roles, RBAC.list_roles())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "assign_role",
        %{"role_id" => role_id, "assignment" => %{"username" => username}},
        socket
      ) do
    role = Enum.find(socket.assigns.roles, &(&1.id == role_id))
    admin = socket.assigns.current_user

    with %{} = user <- Accounts.get_user_by_username(String.trim(username)),
         :ok <- RBAC.assign_role(user, role) do
      Audit.write_finalized(admin, "rbac.role.assign", :success,
        target_kind: "user",
        target_id: user.id,
        params: %{role_name: role.name, username: user.username}
      )

      {:noreply, assign(socket, :roles, RBAC.list_roles())}
    else
      _ -> {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <h1 class="text-2xl font-bold mb-6">Roles</h1>
      <form phx-submit="create_role" class="flex gap-2 mb-6">
        <input
          type="text"
          name="role[name]"
          placeholder="New role name"
          class="input input-bordered input-sm flex-1"
        />
        <button type="submit" class="btn btn-sm btn-primary">Create Role</button>
      </form>
      <div class="space-y-4">
        <div :for={role <- @roles} data-role-id={role.id} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="card-title">{role.name}</h2>
                <p :if={role.description} class="text-sm text-base-content/60">{role.description}</p>
              </div>
              <span :if={role.built_in} class="badge badge-ghost">built-in</span>
            </div>

            <div class="mt-2">
              <span class="text-sm font-medium">Permissions:</span>
              <span :if={role.role_permissions == []} class="text-sm text-base-content/40 ml-1">
                none
              </span>
              <div class="flex flex-wrap gap-1 mt-1">
                <span :for={perm <- role.role_permissions} class="badge badge-outline badge-sm">
                  {perm.action}
                </span>
              </div>
            </div>

            <form phx-submit="grant_permission" class="flex gap-2 mt-2">
              <input type="hidden" name="role_id" value={role.id} />
              <input
                type="text"
                name="permission[action]"
                placeholder="e.g. ssh:node:read"
                class="input input-bordered input-sm flex-1"
              />
              <button type="submit" class="btn btn-sm btn-primary">Grant</button>
            </form>

            <div class="mt-3">
              <span class="text-sm font-medium">Assigned users:</span>
              <span :if={role.user_roles == []} class="text-sm text-base-content/40 ml-1">none</span>
              <div class="flex flex-wrap gap-1 mt-1">
                <span :for={ur <- role.user_roles} class="badge badge-secondary badge-sm">
                  {ur.user.username}
                </span>
              </div>
            </div>

            <form phx-submit="assign_role" class="flex gap-2 mt-2">
              <input type="hidden" name="role_id" value={role.id} />
              <input
                type="text"
                name="assignment[username]"
                placeholder="username"
                class="input input-bordered input-sm flex-1"
              />
              <button type="submit" class="btn btn-sm btn-secondary">Assign</button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
