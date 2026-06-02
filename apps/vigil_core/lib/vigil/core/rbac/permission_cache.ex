defmodule Vigil.Core.RBAC.PermissionCache do
  use GenServer

  import Ecto.Query
  alias Vigil.Repo
  alias Vigil.Core.RBAC.{RolePermission, UserRole}

  @table :rbac_permissions_cache
  @ttl_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  def for_principal(principal_id) do
    now = now_ms()

    case :ets.lookup(@table, principal_id) do
      [{^principal_id, perms, valid_until}] when is_integer(valid_until) ->
        if valid_until > now do
          perms
        else
          rebuild(principal_id, now)
        end

      _ ->
        rebuild(principal_id, now)
    end
  end

  defp rebuild(principal_id, now) do
    perms = load_permissions(principal_id)
    :ets.insert(@table, {principal_id, perms, now + @ttl_ms})
    perms
  end

  def invalidate(principal_id) do
    :ets.delete(@table, principal_id)
    :ok
  end

  defp load_permissions(principal_id) do
    role_ids =
      from(ur in UserRole, where: ur.user_id == ^principal_id, select: ur.role_id)
      |> Repo.all()

    from(rp in RolePermission, where: rp.role_id in ^role_ids)
    |> Repo.all()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
