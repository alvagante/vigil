defmodule VigilWeb.API.ExecutionControllerTest do
  use VigilWeb.LiveCase, async: false

  import Ecto.Query

  alias Vigil.Core.{Accounts, IntegrationConfig, RBAC}
  alias Vigil.Core.Audit.Entry, as: AuditEntry
  alias Vigil.Core.Execution.Record
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
    # exec_test plugin_id → derived action "exec_test:command:execute"
    {:ok, _} = RBAC.grant_permission(role, %{action: "exec_test:command:execute"})
    :ok = RBAC.assign_role(user, role, source: "direct")
  end

  defp grant_action(user, action) do
    {:ok, role} = RBAC.create_role(%{name: "api_role_#{System.unique_integer([:positive])}"})
    {:ok, _} = RBAC.grant_permission(role, %{action: action})
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
          from(e in AuditEntry,
            where: e.action == "execution.submit" and e.actor_user_id == ^user.id
          )
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

    test "accepts task execution with kind=task and derives permission_action from plugin_id" do
      user = make_user("api_task_ok_user")
      token = make_token(user)
      # exec_test plugin_id = "exec_test", kind = task → "exec_test:task:execute"
      grant_action(user, "exec_test:task:execute")
      integ = start_exec_integration("api-task-integ")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{
          "integration_id" => integ.id,
          "kind" => "task",
          "name" => "package",
          "params" => %{"action" => "status", "name" => "nginx"},
          "node_ids" => ["host1"]
        })

      assert resp = json_response(conn, 200)
      assert is_binary(resp["group_id"])
    end

    test "denies task execution when user lacks the derived task permission" do
      user = make_user("api_task_deny_user")
      token = make_token(user)
      # Only exec_test:command:execute, not exec_test:task:execute
      grant_execution(user)
      integ = start_exec_integration("api-task-deny-integ")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{
          "integration_id" => integ.id,
          "kind" => "task",
          "name" => "package",
          "params" => %{},
          "node_ids" => ["host1"]
        })

      assert json_response(conn, 403)["error"] != nil

      # ADR-0005: task denials must be audited with denied_node_ids
      entry =
        Repo.one!(
          from(e in AuditEntry,
            where: e.action == "execution.submit" and e.actor_user_id == ^user.id
          )
        )

      assert entry.result == "denied"
      assert entry.params["denied_node_ids"] == ["host1"]
      # No execution record must have been created
      assert Repo.all(from(r in Record, where: r.node_id == "host1")) == []
    end

    test "denies plan execution when user lacks plan permission and writes a denied audit entry" do
      user = make_user("api_plan_deny_user")
      token = make_token(user)
      # No exec_test:plan:execute granted
      integ = start_exec_integration("api-plan-deny-integ")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{
          "integration_id" => integ.id,
          "kind" => "plan",
          "name" => "reboot",
          "params" => %{"targets" => "host1"}
        })

      assert json_response(conn, 403)["error"] != nil

      # ADR-0005: plan denials use the synthetic __plan__ target
      entry =
        Repo.one!(
          from(e in AuditEntry,
            where: e.action == "execution.submit" and e.actor_user_id == ^user.id
          )
        )

      assert entry.result == "denied"
      assert entry.params["denied_node_ids"] == ["__plan__"]
      assert Repo.all(from(r in Record, where: r.node_id == "__plan__")) == []
    end

    test "accepts plan execution with synthetic __plan__ target when user has plan permission" do
      user = make_user("api_plan_ok_user")
      token = make_token(user)
      grant_action(user, "exec_test:plan:execute")
      integ = start_exec_integration("api-plan-integ")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/executions", %{
          "integration_id" => integ.id,
          "kind" => "plan",
          "name" => "reboot",
          "params" => %{"targets" => "host1"}
        })

      assert resp = json_response(conn, 200)
      assert is_binary(resp["group_id"])
    end
  end
end
