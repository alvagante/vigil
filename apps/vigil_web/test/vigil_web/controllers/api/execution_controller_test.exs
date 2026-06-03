defmodule VigilWeb.API.ExecutionControllerTest do
  use VigilWeb.LiveCase, async: false

  import Ecto.Query

  alias Vigil.Core.{Accounts, IntegrationConfig, RBAC}
  alias Vigil.Core.Audit.Entry, as: AuditEntry
  alias Vigil.Plugin.Catalog
  alias Vigil.Repo
  alias VigilWeb.ExecutionTestPlugin

  setup do
    Catalog.register("exec_test", ExecutionTestPlugin)
    :ok
  end

  defp make_user(name) do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{username: "#{name}_#{n}", password: "api_exec_pass!"})
    user
  end

  defp make_token(user) do
    {:ok, token} = Accounts.mint_token(user, "test-token", [])
    token
  end

  defp grant_execution(user) do
    {:ok, role} = RBAC.create_role(%{name: "api_exec_role_#{System.unique_integer([:positive])}"})
    {:ok, _} = RBAC.grant_permission(role, %{action: "ssh:command:execute"})
    :ok = RBAC.assign_role(user, role, source: "direct")
  end

  defp start_exec_integration(name) do
    {:ok, integ} =
      IntegrationConfig.create(%{
        plugin_id: "exec_test",
        name: name,
        contract_version: "1.0.0",
        enabled: true
      })

    start_supervised!(ExecutionTestPlugin.child_spec({integ.id, %{}}))
    integ
  end

  describe "POST /api/v1/executions" do
    test "returns 401 when no token is provided" do
      conn = post(build_conn(), "/api/v1/executions", %{})
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 422 when required fields are missing" do
      user = make_user("api_missing_user")
      token = make_token(user)
      grant_execution(user)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{})

      assert json_response(conn, 422)["error"] != nil
    end

    test "returns 403 when user lacks permission and writes a denied audit entry" do
      user = make_user("api_no_perm_user")
      token = make_token(user)
      integ = start_exec_integration("api-no-perm-integ")
      # No role assigned — RBAC denies all targets

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{
          "integration_id" => integ.id,
          "command" => "uptime",
          "node_ids" => ["host1"]
        })

      assert json_response(conn, 403)["error"] != nil

      # ADR-0005: denials must be audited identically to session requests
      entry =
        Repo.one!(
          from e in AuditEntry,
            where: e.action == "execution.submit" and e.actor_user_id == ^user.id
        )

      assert entry.result == "denied"
      assert entry.params["denied_node_ids"] == ["host1"]
    end

    test "returns 200 and group_id when submission succeeds" do
      user = make_user("api_ok_user")
      token = make_token(user)
      grant_execution(user)
      integ = start_exec_integration("api-test-integ")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{
          "integration_id" => integ.id,
          "command" => "uptime",
          "node_ids" => ["host1"]
        })

      assert resp = json_response(conn, 200)
      assert is_binary(resp["group_id"])
    end
  end
end
