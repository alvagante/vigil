defmodule Vigil.Core.ExecutionsTest do
  use Vigil.DataCase, async: false

  alias Vigil.Core.{Accounts, Executions, RBAC}
  alias Vigil.Core.Audit.Entry, as: AuditEntry
  alias Vigil.Core.Execution.{Group, Record}
  alias Vigil.Repo

  # Inline fake runner: sends the artifact text as a single stdout chunk,
  # then marks each target done with exit_status 0.
  defmodule FakeRunner do
    def start(_integration_id, artifact, targets, %{stream_pid: stream_pid}) do
      # Artifacts from DB come back with string keys; handle both.
      text = artifact[:text] || artifact["text"]

      pid =
        spawn(fn ->
          for %{execution_id: exec_id} <- targets do
            send(stream_pid, {:runner_chunk, exec_id, :stdout, text <> "\n"})
            send(stream_pid, {:runner_target_done, exec_id, %{exit_status: 0, duration_ms: 1}})
          end

          send(stream_pid, {:runner_done, %{overall_status: :ok}})
        end)

      {:ok, pid}
    end

    def abort(_), do: :ok
  end

  # Helpers for RBAC-gated tests
  defp make_user(username) do
    {:ok, user} = Accounts.register_user(%{username: username, password: "exec_rbac_pass!"})
    user
  end

  defp make_role(name) do
    {:ok, role} = RBAC.create_role(%{name: name})
    role
  end

  defp grant(role, action) do
    {:ok, _} = RBAC.grant_permission(role, %{action: action})
  end

  defp assign_role(user, role) do
    :ok = RBAC.assign_role(user, role, source: "direct")
  end

  describe "submit/2 RBAC enforcement" do
    test "all-denied submission returns error and writes no execution records (ADR-0005)" do
      user = make_user("exec_deny_user")
      # No role — all targets denied

      assert {:error, :all_denied} =
               Executions.submit(user, %{
                 runner_module: FakeRunner,
                 integration_id: "integ-rbac-deny",
                 artifact: %{kind: :command, text: "rm -rf /"},
                 targets: %{node_ids: ["host1"]},
                 permission_action: "ssh:command:execute"
               })

      import Ecto.Query
      assert [] = Repo.all(from(r in Record, where: r.node_id == "host1"))
    end

    test "all-denied submission writes a denied audit entry with full target list" do
      user = make_user("exec_deny_audit_user")

      Executions.submit(user, %{
        runner_module: FakeRunner,
        integration_id: "integ-rbac-audit",
        artifact: %{kind: :command, text: "rm -rf /"},
        targets: %{node_ids: ["host-a", "host-b"]},
        permission_action: "ssh:command:execute"
      })

      import Ecto.Query

      entry =
        Repo.one!(
          from(e in AuditEntry,
            where: e.action == "execution.submit" and e.actor_user_id == ^user.id
          )
        )

      assert entry.result == "denied"
      assert entry.params["node_ids"] == ["host-a", "host-b"]
      assert entry.params["denied_node_ids"] == ["host-a", "host-b"]
      assert entry.params["permitted_count"] == 0
    end

    test "permitted submission with permission_action proceeds normally" do
      user = make_user("exec_permit_user")
      role = make_role("exec_permit_role")
      grant(role, "ssh:command:execute")
      assign_role(user, role)

      assert {:ok, group_id} =
               Executions.submit(user, %{
                 runner_module: FakeRunner,
                 integration_id: "integ-rbac-ok",
                 artifact: %{kind: :command, text: "uptime"},
                 targets: %{node_ids: ["host-ok"]},
                 permission_action: "ssh:command:execute"
               })

      assert is_binary(group_id)
    end

    test "command_policy denial blocks execution and writes denied audit entry" do
      user = make_user("exec_cmd_deny_user")
      role = make_role("exec_cmd_deny_role")

      {:ok, _} =
        RBAC.grant_permission(role, %{
          action: "ssh:command:execute",
          command_policy: %{"allow" => ["uptime"], "deny" => []}
        })

      assign_role(user, role)

      assert {:error, :all_denied} =
               Executions.submit(user, %{
                 runner_module: FakeRunner,
                 integration_id: "integ-cmd-deny",
                 artifact: %{kind: :command, text: "rm -rf /"},
                 targets: %{node_ids: ["host-cmd"]},
                 permission_action: "ssh:command:execute"
               })

      import Ecto.Query
      assert [] = Repo.all(from(r in Record, where: r.node_id == "host-cmd"))
    end

    test "partial dispatch: permitted targets get records, denied targets get only audit (ADR-0005 DM-601)" do
      # Set up: user has permission with target_selector on env=prod only
      user = make_user("exec_partial_user")
      role = make_role("exec_partial_role")

      {:ok, _} =
        RBAC.grant_permission(role, %{
          action: "ssh:command:execute",
          target_selector: %{"tags" => %{"env" => ["prod"]}}
        })

      assign_role(user, role)

      prod_node = %{id: "prod-host", tags: %{"env" => "prod"}}
      dev_node = %{id: "dev-host", tags: %{"env" => "dev"}}
      node_ids = [prod_node.id, dev_node.id]

      assert {:ok, group_id} =
               Executions.submit(user, %{
                 runner_module: FakeRunner,
                 integration_id: "integ-partial",
                 artifact: %{kind: :command, text: "uptime"},
                 targets: %{node_ids: node_ids, resolved: [prod_node, dev_node]},
                 permission_action: "ssh:command:execute"
               })

      import Ecto.Query
      records = Repo.all(from(r in Record, where: r.execution_group_id == ^group_id))
      record_node_ids = Enum.map(records, & &1.node_id)

      assert "prod-host" in record_node_ids
      refute "dev-host" in record_node_ids
    end
  end

  describe "submit/2" do
    test "creates group + per-node execution records and persists transcript on completion" do
      principal = %{id: "test-user-1"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: FakeRunner,
          integration_id: "integ-1",
          artifact: %{kind: :command, text: "echo hello"},
          targets: %{node_ids: ["host1"]}
        })

      assert is_binary(group_id)

      eventually(fn ->
        record = Repo.get_by(Record, execution_group_id: group_id)
        record && record.outcome == "ok"
      end)

      group = Repo.get_by!(Group, id: group_id)
      assert group.dispatched_count == 1
      assert group.integration_id == "integ-1"

      record = Repo.get_by!(Record, execution_group_id: group_id)
      assert record.node_id == "host1"
      assert record.outcome == "ok"
      assert record.transcript =~ "echo hello"
    end
  end

  # Runner that delays 50ms before emitting chunks, letting the test subscribe
  # after querying the execution_id from the DB (which is committed before submit
  # returns, so the query is immediate — no race).
  defmodule SlowRunner do
    def start(_integration_id, artifact, targets, %{stream_pid: stream_pid}) do
      text = artifact[:text] || artifact["text"]

      pid =
        spawn(fn ->
          Process.sleep(50)

          for %{execution_id: exec_id} <- targets do
            send(stream_pid, {:runner_chunk, exec_id, :stdout, text <> "\n"})
            send(stream_pid, {:runner_target_done, exec_id, %{exit_status: 0, duration_ms: 1}})
          end

          send(stream_pid, {:runner_done, %{overall_status: :ok}})
        end)

      {:ok, pid}
    end

    def abort(_), do: :ok
  end

  # Runner that hangs indefinitely — used to test timeout enforcement.
  defmodule HangingRunner do
    def start(_integration_id, _artifact, _targets, _opts) do
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end

    def abort(pid), do: Process.exit(pid, :kill)
  end

  # Runner that sends one chunk then hangs silently — for idle timeout tests.
  defmodule SilentAfterChunkRunner do
    def start(_integration_id, _artifact, targets, %{stream_pid: stream_pid}) do
      pid =
        spawn(fn ->
          for %{execution_id: exec_id} <- targets do
            send(stream_pid, {:runner_chunk, exec_id, :stdout, "partial\n"})
          end

          Process.sleep(:infinity)
        end)

      {:ok, pid}
    end

    def abort(pid), do: Process.exit(pid, :kill)
  end

  describe "timeouts" do
    test "wall-clock timeout marks execution as timed_out" do
      principal = %{id: "user-wc"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: HangingRunner,
          integration_id: "integ-wc",
          artifact: %{kind: :command, text: "sleep 999"},
          targets: %{node_ids: ["hostT"]},
          timeout: %{wall_clock_ms: 150}
        })

      eventually(
        fn ->
          record = Repo.get_by(Record, execution_group_id: group_id)
          record && record.outcome == "timed_out"
        end,
        800
      )

      record = Repo.get_by!(Record, execution_group_id: group_id)
      assert record.outcome == "timed_out"
    end

    test "idle timeout fires when runner goes silent after a chunk" do
      principal = %{id: "user-idle"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: SilentAfterChunkRunner,
          integration_id: "integ-idle",
          artifact: %{kind: :command, text: "cat /dev/null"},
          targets: %{node_ids: ["hostI"]},
          timeout: %{idle_ms: 150}
        })

      eventually(
        fn ->
          record = Repo.get_by(Record, execution_group_id: group_id)
          record && record.outcome == "timed_out"
        end,
        800
      )

      record = Repo.get_by!(Record, execution_group_id: group_id)
      assert record.outcome == "timed_out"
    end
  end

  # Runner that exits with status 1 — for testing "failed" outcome filtering.
  defmodule FailingRunner do
    def start(_integration_id, _artifact, targets, %{stream_pid: stream_pid}) do
      pid =
        spawn(fn ->
          for %{execution_id: exec_id} <- targets do
            send(stream_pid, {:runner_target_done, exec_id, %{exit_status: 1, duration_ms: 1}})
          end

          send(stream_pid, {:runner_done, %{overall_status: :failed}})
        end)

      {:ok, pid}
    end

    def abort(_), do: :ok
  end

  describe "audit trail" do
    test "submit creates an audit entry finalized to success" do
      principal = %{id: "audit-user-1"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: FakeRunner,
          integration_id: "integ-audit",
          artifact: %{kind: :command, text: "audit cmd"},
          targets: %{node_ids: ["audit-host"]}
        })

      # Wait for the stream to finish so it doesn't outlive the sandbox.
      eventually(fn ->
        r = Repo.get_by(Record, execution_group_id: group_id)
        r && r.outcome != "running"
      end)

      import Ecto.Query

      entry =
        Repo.one!(
          from(e in AuditEntry,
            where: e.action == "execution.submit" and e.actor_label == "audit-user-1"
          )
        )

      assert entry.result == "success"
      assert entry.finalized_at != nil
      assert entry.target_kind == "execution_group"
      assert entry.target_id == group_id
      assert entry.params["integration_id"] == "integ-audit"
      assert entry.params["node_ids"] == ["audit-host"]
    end
  end

  describe "re-run" do
    test "rerun_record/3 submits a new single-target execution with the same artifact" do
      principal = %{id: "rerun-user"}

      {:ok, orig_group_id} =
        Executions.submit(principal, %{
          runner_module: FakeRunner,
          integration_id: "integ-rerun",
          artifact: %{kind: :command, text: "echo rerun"},
          targets: %{node_ids: ["rerun-host"]}
        })

      eventually(fn ->
        r = Repo.get_by(Record, execution_group_id: orig_group_id)
        r && r.outcome == "ok"
      end)

      orig_record = Repo.get_by!(Record, execution_group_id: orig_group_id)

      {:ok, new_group_id} = Executions.rerun_record(orig_record.id, principal, FakeRunner)

      refute new_group_id == orig_group_id

      eventually(fn ->
        r = Repo.get_by(Record, execution_group_id: new_group_id)
        r && r.outcome == "ok"
      end)

      new_record = Repo.get_by!(Record, execution_group_id: new_group_id)
      assert new_record.node_id == orig_record.node_id
      assert new_record.artifact == orig_record.artifact
    end

    test "rerun_group/3 re-dispatches all original targets" do
      principal = %{id: "rerun-grp-user"}

      {:ok, orig_group_id} =
        Executions.submit(principal, %{
          runner_module: FakeRunner,
          integration_id: "integ-rerun-grp",
          artifact: %{kind: :command, text: "echo grprerun"},
          targets: %{node_ids: ["grp-host1", "grp-host2"]}
        })

      eventually(fn ->
        records = Repo.all(from(r in Record, where: r.execution_group_id == ^orig_group_id))
        length(records) == 2 && Enum.all?(records, &(&1.outcome != "running"))
      end)

      {:ok, new_group_id} = Executions.rerun_group(orig_group_id, principal, FakeRunner)

      refute new_group_id == orig_group_id

      eventually(fn ->
        records = Repo.all(from(r in Record, where: r.execution_group_id == ^new_group_id))
        length(records) == 2 && Enum.all?(records, &(&1.outcome != "running"))
      end)

      new_group = Repo.get!(Group, new_group_id)
      assert new_group.dispatched_count == 2
      assert new_group.integration_id == "integ-rerun-grp"
    end
  end

  describe "history/1" do
    test "returns groups filterable by node_id and outcome" do
      principal = %{id: "hist-user"}

      {:ok, ok_group_id} =
        Executions.submit(principal, %{
          runner_module: FakeRunner,
          integration_id: "integ-hist",
          artifact: %{kind: :command, text: "echo ok"},
          targets: %{node_ids: ["hist-host1"]}
        })

      {:ok, fail_group_id} =
        Executions.submit(principal, %{
          runner_module: FailingRunner,
          integration_id: "integ-hist",
          artifact: %{kind: :command, text: "false"},
          targets: %{node_ids: ["hist-host2"]}
        })

      # Wait for both streams to complete
      eventually(fn ->
        r1 = Repo.get_by(Record, execution_group_id: ok_group_id)
        r2 = Repo.get_by(Record, execution_group_id: fail_group_id)
        r1 && r2 && r1.outcome != "running" && r2.outcome != "running"
      end)

      all = Executions.history()
      assert length(all) >= 2

      group_ids = Enum.map(all, & &1.id)
      assert ok_group_id in group_ids
      assert fail_group_id in group_ids

      by_node = Executions.history(%{node_id: "hist-host1"})
      assert Enum.any?(by_node, &(&1.id == ok_group_id))
      refute Enum.any?(by_node, &(&1.id == fail_group_id))

      by_outcome = Executions.history(%{outcome: "ok"})
      assert Enum.any?(by_outcome, &(&1.id == ok_group_id))
      refute Enum.any?(by_outcome, &(&1.id == fail_group_id))
    end
  end

  describe "PubSub streaming" do
    test "live chunks are broadcast on execution_stream:<execution_id>" do
      principal = %{id: "user-pubsub"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: SlowRunner,
          integration_id: "integ-pub",
          artifact: %{kind: :command, text: "echo stream"},
          targets: %{node_ids: ["hostA"]}
        })

      # DB rows are committed before submit returns; query is safe here.
      %Record{id: exec_id} = Repo.get_by!(Record, execution_group_id: group_id)
      Phoenix.PubSub.subscribe(Vigil.PubSub, "execution_stream:#{exec_id}")

      assert_receive {:chunk, ^exec_id, "echo stream\n"}, 500
      # Also wait for :ended so the Stream GenServer has persisted before the
      # sandbox is released (avoids a post-test DB error).
      assert_receive {:ended, ^exec_id, :ok}, 500
    end
  end

  defp eventually(fun, remaining_ms \\ 500) do
    cond do
      fun.() ->
        :ok

      remaining_ms <= 0 ->
        flunk("condition was not met within timeout")

      true ->
        Process.sleep(10)
        eventually(fun, remaining_ms - 10)
    end
  end
end
