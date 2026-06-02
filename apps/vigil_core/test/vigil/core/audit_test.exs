defmodule Vigil.Core.AuditTest do
  use Vigil.DataCase, async: true

  alias Vigil.Core.{Accounts, Audit}
  alias Vigil.Core.Audit.Entry
  alias Vigil.Repo

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp unique_username do
    n = System.unique_integer([:positive, :monotonic])
    "audit_user_#{n}"
  end

  defp user_fixture do
    {:ok, user} = Accounts.register_user(%{username: unique_username(), password: "password_audit!"})
    user
  end

  # ── cycle 1: write_pending happy path ───────────────────────────────────────

  describe "write_pending/3" do
    test "inserts a row with result pending and no finalized_at" do
      assert {:ok, entry} = Audit.write_pending(nil, "test.action")

      assert entry.result == "pending"
      assert entry.action == "test.action"
      assert entry.finalized_at == nil
      assert entry.occurred_at != nil
    end

    # cycle 2: User actor → actor_user_id
    test "routes %User{} to actor_user_id" do
      user = user_fixture()

      assert {:ok, entry} = Audit.write_pending(user, "test.action")

      assert entry.actor_user_id == user.id
      assert entry.actor_label == nil
    end

    # cycle 3: bare-map actor → actor_label
    test "routes bare-map principal to actor_label" do
      principal = %{id: "system-process-1"}

      assert {:ok, entry} = Audit.write_pending(principal, "test.action")

      assert entry.actor_user_id == nil
      assert entry.actor_label == "system-process-1"
    end

    test "nil actor leaves both actor fields nil" do
      assert {:ok, entry} = Audit.write_pending(nil, "system.event")

      assert entry.actor_user_id == nil
      assert entry.actor_label == nil
    end

    test "accepts optional target_kind, target_id, and params" do
      assert {:ok, entry} =
               Audit.write_pending(nil, "test.action",
                 target_kind: "node",
                 target_id: "node-123",
                 params: %{node_count: 5}
               )

      assert entry.target_kind == "node"
      assert entry.target_id == "node-123"
      assert entry.params["node_count"] == 5
    end
  end

  # ── cycle 4-6: finalize/2 ───────────────────────────────────────────────────

  describe "finalize/2" do
    test "transitions pending → success" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")

      assert {:ok, finalized} = Audit.finalize(entry, :success)

      assert finalized.result == "success"
      assert finalized.finalized_at != nil
    end

    test "transitions pending → failure" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")

      assert {:ok, finalized} = Audit.finalize(entry, :failure)

      assert finalized.result == "failure"
    end

    test "transitions pending → denied" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")

      assert {:ok, finalized} = Audit.finalize(entry, :denied)

      assert finalized.result == "denied"
    end

    test "persists the transition to the DB" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")
      {:ok, _} = Audit.finalize(entry, :success)

      db_entry = Repo.get!(Entry, entry.id)
      assert db_entry.result == "success"
      assert db_entry.finalized_at != nil
    end

    # cycle 6: already-finalized guard
    test "returns :already_finalized for a non-pending entry" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")
      {:ok, finalized} = Audit.finalize(entry, :success)

      assert {:error, :already_finalized} = Audit.finalize(finalized, :success)
    end
  end

  # ── cycle 7: write_finalized/4 ──────────────────────────────────────────────

  describe "write_finalized/4" do
    test "inserts a directly-finalized entry" do
      assert {:ok, entry} = Audit.write_finalized(nil, "auth.login", :success)

      assert entry.result == "success"
      assert entry.finalized_at != nil
    end

    test "accepts :denied result" do
      assert {:ok, entry} = Audit.write_finalized(nil, "execution.submit", :denied)

      assert entry.result == "denied"
    end

    test "accepts target and params options" do
      assert {:ok, entry} =
               Audit.write_finalized(nil, "auth.login", :success,
                 target_kind: "user",
                 target_id: "user-1",
                 params: %{break_glass: true}
               )

      assert entry.target_kind == "user"
      assert entry.params["break_glass"] == true
    end

    test "routes %User{} to actor_user_id" do
      user = user_fixture()

      assert {:ok, entry} = Audit.write_finalized(user, "auth.login", :success)

      assert entry.actor_user_id == user.id
    end
  end

  # ── cycle 8: changeset immutability ─────────────────────────────────────────

  describe "changeset immutability" do
    test "update_changeset/2 on a finalized entry is invalid" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")
      {:ok, finalized} = Audit.finalize(entry, :success)

      changeset = Entry.update_changeset(finalized, %{action: "tampered.action"})

      refute changeset.valid?
      assert errors_on(changeset).result != nil
    end

    test "Repo.update/1 of a finalized entry via update_changeset fails" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")
      {:ok, finalized} = Audit.finalize(entry, :success)

      changeset = Entry.update_changeset(finalized, %{action: "tampered"})

      assert {:error, %Ecto.Changeset{}} = Repo.update(changeset)
    end
  end

  # ── cycle 9: Postgres immutability trigger ───────────────────────────────────

  describe "Postgres immutability trigger" do
    test "raw UPDATE on a finalized entry raises at the DB level" do
      {:ok, entry} = Audit.write_pending(nil, "test.action")
      {:ok, _} = Audit.finalize(entry, :success)

      # Must be the last DB operation in this test — the trigger RAISE aborts
      # the surrounding sandbox transaction, poisoning the connection for any
      # subsequent Repo call.
      assert_raise Postgrex.Error, fn ->
        import Ecto.Query

        Repo.update_all(
          from(e in Entry, where: e.id == ^entry.id),
          set: [action: "tampered"]
        )
      end
    end
  end
end
