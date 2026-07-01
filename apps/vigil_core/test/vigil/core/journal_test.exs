defmodule Vigil.Core.JournalTest do
  use Vigil.DataCase, async: false

  alias Vigil.Core.Journal
  alias Vigil.Core.Journal.Entry

  # ──────────────────────────────────────────────
  # Tracer 1: create_execution_entry / schema
  # ──────────────────────────────────────────────

  describe "create_execution_entry/1" do
    test "inserts a journal entry and returns {:ok, %Entry{}}" do
      assert {:ok, entry} =
               Journal.create_execution_entry(%{
                 node_id: "node-web-01",
                 summary: "command: uptime",
                 severity: "informational",
                 occurred_at: DateTime.utc_now()
               })

      assert entry.node_id == "node-web-01"
      assert entry.entry_type == "execution"
      assert entry.summary == "command: uptime"
      assert entry.severity == "informational"
      assert %Entry{} = entry
    end

    test "links to an execution record when execution_id is provided" do
      exec_id = insert_execution()

      assert {:ok, entry} =
               Journal.create_execution_entry(%{
                 node_id: "node-web-01",
                 execution_id: exec_id,
                 summary: "command: hostname",
                 severity: "informational",
                 occurred_at: DateTime.utc_now()
               })

      assert entry.execution_id == exec_id
    end

    test "requires node_id and summary" do
      assert {:error, changeset} = Journal.create_execution_entry(%{severity: "informational"})
      errors = errors_on(changeset)
      assert :node_id in Map.keys(errors)
      assert :summary in Map.keys(errors)
    end

    test "defaults severity to informational when omitted" do
      assert {:ok, entry} =
               Journal.create_execution_entry(%{
                 node_id: "node-db-01",
                 summary: "script ran",
                 occurred_at: DateTime.utc_now()
               })

      assert entry.severity == "informational"
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 2: local_entries/2 — per-node query
  # ──────────────────────────────────────────────

  describe "local_entries/2" do
    test "returns entries for the given node ordered by occurred_at DESC" do
      t1 = ~U[2026-06-01 10:00:00Z]
      t2 = ~U[2026-06-01 12:00:00Z]

      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "older", occurred_at: t1})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "newer", occurred_at: t2})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-b", summary: "other node", occurred_at: t2})

      entries = Journal.local_entries("node-a", %{})
      assert length(entries) == 2
      assert hd(entries).summary == "newer"
      assert List.last(entries).summary == "older"
    end

    test "returns empty list when node has no entries" do
      assert Journal.local_entries("ghost-node", %{}) == []
    end

    test "filters by entry_type" do
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "exec", occurred_at: DateTime.utc_now()})
      {:ok, _} = insert_note("node-a", "manual note")

      exec_entries = Journal.local_entries("node-a", %{entry_type: "execution"})
      note_entries = Journal.local_entries("node-a", %{entry_type: "manual_note"})

      assert length(exec_entries) == 1
      assert hd(exec_entries).entry_type == "execution"
      assert length(note_entries) == 1
      assert hd(note_entries).entry_type == "manual_note"
    end

    test "filters by severity" do
      {:ok, _} =
        Journal.create_execution_entry(%{
          node_id: "node-a",
          summary: "ok run",
          severity: "informational",
          occurred_at: DateTime.utc_now()
        })

      {:ok, _} =
        Journal.create_execution_entry(%{
          node_id: "node-a",
          summary: "failed run",
          severity: "error",
          occurred_at: DateTime.utc_now()
        })

      errors = Journal.local_entries("node-a", %{severity: "error"})
      assert length(errors) == 1
      assert hd(errors).severity == "error"
    end

    test "filters by time_range" do
      old = ~U[2026-01-01 00:00:00Z]
      recent = ~U[2026-06-01 00:00:00Z]

      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "old", occurred_at: old})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "recent", occurred_at: recent})

      from = ~U[2026-05-01 00:00:00Z]
      entries = Journal.local_entries("node-a", %{time_range: {from, nil}})
      assert length(entries) == 1
      assert hd(entries).summary == "recent"
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 3: local_entries_global/1
  # ──────────────────────────────────────────────

  describe "local_entries_global/1" do
    test "returns entries across all nodes ordered by occurred_at DESC" do
      t1 = ~U[2026-06-01 10:00:00Z]
      t2 = ~U[2026-06-01 12:00:00Z]

      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "a", occurred_at: t1})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-b", summary: "b", occurred_at: t2})

      entries = Journal.local_entries_global(%{})
      assert length(entries) >= 2
      timestamps = Enum.map(entries, & &1.occurred_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "applies time_range filter globally" do
      old = ~U[2026-01-01 00:00:00Z]
      recent = ~U[2026-06-01 00:00:00Z]

      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-a", summary: "old", occurred_at: old})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-b", summary: "recent", occurred_at: recent})

      from = ~U[2026-05-01 00:00:00Z]
      entries = Journal.local_entries_global(%{time_range: {from, nil}})
      assert Enum.all?(entries, fn e -> DateTime.compare(e.occurred_at, from) in [:gt, :eq] end)
      assert Enum.any?(entries, fn e -> e.summary == "recent" end)
      refute Enum.any?(entries, fn e -> e.summary == "old" end)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 4: Manual notes — create / update / author-only (DM-501)
  # ──────────────────────────────────────────────

  describe "Notes.create/2" do
    test "creates a manual_note entry" do
      principal = make_principal()

      assert {:ok, entry} =
               Journal.Notes.create(principal, %{
                 node_id: "node-a",
                 summary: "investigated high load",
                 detail: %{"root_cause" => "runaway cron"},
                 tags: ["incident"]
               })

      assert entry.entry_type == "manual_note"
      assert entry.summary == "investigated high load"
      assert entry.author_user_id == principal.id
      assert entry.severity == "notice"
    end
  end

  describe "Notes.update/3" do
    test "updates the entry and writes a revision row" do
      principal = make_principal()
      {:ok, entry} = Journal.Notes.create(principal, %{node_id: "node-a", summary: "original"})

      assert {:ok, updated} = Journal.Notes.update(principal, entry.id, %{summary: "revised"})
      assert updated.summary == "revised"

      revisions = Journal.Notes.revisions(entry.id)
      assert length(revisions) == 1
      assert hd(revisions).previous_summary == "original"
    end

    test "returns {:error, :unauthorized} when non-author edits (DM-501)" do
      author = make_principal()
      other = make_principal(suffix: "other")

      {:ok, entry} = Journal.Notes.create(author, %{node_id: "node-a", summary: "mine"})

      assert {:error, :unauthorized} = Journal.Notes.update(other, entry.id, %{summary: "hijacked"})
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 3a: local_entries_global — node filter (JRN-102)
  # ──────────────────────────────────────────────

  describe "local_entries_global/1 node filter" do
    test "node_id filter returns only entries for that node" do
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-x", summary: "x-entry", occurred_at: DateTime.utc_now()})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-y", summary: "y-entry", occurred_at: DateTime.utc_now()})

      entries = Journal.local_entries_global(%{node_id: "node-x"})
      assert Enum.all?(entries, fn e -> e.node_id == "node-x" end)
      assert Enum.any?(entries, fn e -> e.summary == "x-entry" end)
      refute Enum.any?(entries, fn e -> e.summary == "y-entry" end)
    end

    test "node_ids filter returns only entries for those nodes" do
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-1", summary: "n1", occurred_at: DateTime.utc_now()})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-2", summary: "n2", occurred_at: DateTime.utc_now()})
      {:ok, _} = Journal.create_execution_entry(%{node_id: "node-3", summary: "n3", occurred_at: DateTime.utc_now()})

      entries = Journal.local_entries_global(%{node_ids: ["node-1", "node-2"]})
      assert Enum.all?(entries, fn e -> e.node_id in ["node-1", "node-2"] end)
      refute Enum.any?(entries, fn e -> e.node_id == "node-3" end)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 4a: Notes.delete/2 soft-delete (DM-501 + audit)
  # ──────────────────────────────────────────────

  describe "Notes.delete/2" do
    test "soft-deletes the entry (sets deleted_at)" do
      principal = make_principal()
      {:ok, entry} = Journal.Notes.create(principal, %{node_id: "node-a", summary: "to be deleted"})

      assert {:ok, deleted} = Journal.Notes.delete(principal, entry.id)
      assert deleted.deleted_at != nil

      entries = Journal.local_entries("node-a", %{})
      refute Enum.any?(entries, fn e -> e.id == entry.id end)
    end

    test "returns {:error, :unauthorized} for non-author" do
      author = make_principal()
      other = make_principal(suffix: "other2")

      {:ok, entry} = Journal.Notes.create(author, %{node_id: "node-a", summary: "mine"})

      assert {:error, :unauthorized} = Journal.Notes.delete(other, entry.id)

      entries = Journal.local_entries("node-a", %{})
      assert Enum.any?(entries, fn e -> e.id == entry.id end)
    end

    test "deleted entry does not appear in local_entries_global" do
      principal = make_principal()
      {:ok, entry} = Journal.Notes.create(principal, %{node_id: "node-del", summary: "gone"})
      {:ok, _} = Journal.Notes.delete(principal, entry.id)

      global = Journal.local_entries_global(%{})
      refute Enum.any?(global, fn e -> e.id == entry.id end)
    end
  end

  # ──────────────────────────────────────────────
  # Tracer 5: PubSub broadcast on create
  # ──────────────────────────────────────────────

  describe "PubSub" do
    test "create_execution_entry/1 broadcasts to journal:node and journal:global" do
      Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:node:node-pub-01")
      Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:global")

      assert {:ok, entry} =
               Journal.create_execution_entry(%{
                 node_id: "node-pub-01",
                 summary: "broadcast test",
                 occurred_at: DateTime.utc_now()
               })

      assert_receive {:journal_entry_created, ^entry}, 500
      assert_receive {:journal_entry_created, ^entry}, 500
    end

    test "Notes.create/2 broadcasts to journal:node and journal:global" do
      Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:node:node-note-pub")
      Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:global")

      principal = make_principal()

      assert {:ok, entry} =
               Journal.Notes.create(principal, %{
                 node_id: "node-note-pub",
                 summary: "note broadcast"
               })

      assert_receive {:journal_entry_created, ^entry}, 500
      assert_receive {:journal_entry_created, ^entry}, 500
    end

    test "Notes.delete/2 broadcasts :journal_entry_deleted to journal:global" do
      Phoenix.PubSub.subscribe(Vigil.PubSub, "journal:global")

      principal = make_principal()
      {:ok, entry} = Journal.Notes.create(principal, %{node_id: "node-del-pub", summary: "bye"})

      # clear the create broadcast
      assert_receive {:journal_entry_created, _}, 500

      {:ok, deleted} = Journal.Notes.delete(principal, entry.id)
      assert_receive {:journal_entry_deleted, ^deleted}, 500
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp insert_execution do
    group = Vigil.Repo.insert!(%Vigil.Core.Execution.Group{
      integration_id: "test-integration",
      artifact: %{kind: "command", text: "uptime"},
      intended_targets: %{},
      submitted_by: "test",
      submitted_at: DateTime.utc_now()
    })

    record = Vigil.Repo.insert!(%Vigil.Core.Execution.Record{
      execution_group_id: group.id,
      integration_id: "test-integration",
      node_id: "node-web-01",
      artifact: %{kind: "command", text: "uptime"},
      outcome: "ok"
    })

    record.id
  end

  defp insert_note(node_id, summary) do
    p = make_principal()
    Journal.Notes.create(p, %{node_id: node_id, summary: summary})
  end

  defp make_principal(opts \\ []) do
    suffix = opts[:suffix] || System.unique_integer([:positive]) |> to_string()

    {:ok, user} =
      Vigil.Core.Accounts.register_user(%{
        username: "journal_user_#{suffix}",
        password: "journal_test_pass!"
      })

    user
  end
end
