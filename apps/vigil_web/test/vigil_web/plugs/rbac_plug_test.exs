defmodule VigilWeb.RBACPlugTest do
  use VigilWeb.LiveCase, async: true

  alias Vigil.Core.{Accounts, RBAC}
  alias VigilWeb.RBACPlug

  defp unique_user do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, user} =
      Accounts.register_user(%{username: "rbac_plug_#{n}", password: "rbac_plug_pass!"})

    user
  end

  defp role_with_permission(action) do
    n = System.unique_integer([:positive, :monotonic])
    {:ok, role} = RBAC.create_role(%{name: "rbac_plug_role_#{n}"})
    {:ok, _} = RBAC.grant_permission(role, %{action: action})
    role
  end

  defp conn_with_user(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.assign(:current_user, user)
  end

  describe "call/2" do
    test "allows conn through when user has the required permission" do
      user = unique_user()
      role = role_with_permission("ssh:command:execute")
      :ok = RBAC.assign_role(user, role, source: "direct")

      conn = conn_with_user(user) |> RBACPlug.call(permission: "ssh:command:execute")

      refute conn.halted
    end

    test "halts with 403 when user lacks the required permission" do
      user = unique_user()
      role = role_with_permission("puppet:inventory:read")
      :ok = RBAC.assign_role(user, role, source: "direct")

      conn = conn_with_user(user) |> RBACPlug.call(permission: "ssh:command:execute")

      assert conn.halted
      assert conn.status == 403
    end

    test "halts with 401 when no user is authenticated" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user, nil)
        |> RBACPlug.call(permission: "ssh:command:execute")

      assert conn.halted
      assert conn.status == 401
    end
  end
end
