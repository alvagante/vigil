defmodule Vigil.Core.Execution.RecoveryTest do
  use Vigil.DataCase, async: false

  alias Vigil.Core.Execution.{Record, Recovery}
  alias Vigil.Core.Executions
  alias Vigil.Repo

  defmodule HangingRunner do
    def start(_integration_id, _artifact, _targets, _opts),
      do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}

    def abort(pid), do: Process.exit(pid, :kill)
  end

  describe "recover_in_flight/0" do
    test "marks running executions as aborted_by_restart and closes streaming_state" do
      principal = %{id: "recovery-user-1"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: HangingRunner,
          integration_id: "integ-rec-1",
          artifact: %{kind: :command, text: "recovery test"},
          targets: %{node_ids: ["rec-host-1"]},
          timeout: %{wall_clock_ms: 60_000}
        })

      on_exit(fn ->
        case GenServer.whereis(Vigil.Core.Execution.Stream.via(group_id)) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end
      end)

      %Record{id: exec_id} = Repo.get_by!(Record, execution_group_id: group_id)
      assert Repo.get!(Record, exec_id).outcome == "running"

      Recovery.recover_in_flight()

      record = Repo.get!(Record, exec_id)
      assert record.outcome == "aborted_by_restart"
      assert record.streaming_state == "closed"
    end

    test "promotes partial_transcript to transcript with abort marker appended" do
      principal = %{id: "recovery-user-2"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: HangingRunner,
          integration_id: "integ-rec-2",
          artifact: %{kind: :command, text: "partial recovery"},
          targets: %{node_ids: ["rec-host-2"]},
          timeout: %{wall_clock_ms: 60_000}
        })

      on_exit(fn ->
        case GenServer.whereis(Vigil.Core.Execution.Stream.via(group_id)) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end
      end)

      %Record{id: exec_id} = Repo.get_by!(Record, execution_group_id: group_id)

      # Simulate a partial transcript (gzipped "partial output\n").
      gzipped = :zlib.gzip("partial output\n")
      Repo.get!(Record, exec_id) |> Ecto.Changeset.change(partial_transcript: gzipped) |> Repo.update!()

      Recovery.recover_in_flight()

      record = Repo.get!(Record, exec_id)
      transcript_text = :zlib.gunzip(record.transcript)
      assert transcript_text =~ "partial output"
      assert transcript_text =~ "ABORTED"
    end

    test "does not touch executions that are already in a terminal state" do
      principal = %{id: "recovery-user-3"}

      {:ok, group_id} =
        Executions.submit(principal, %{
          runner_module: HangingRunner,
          integration_id: "integ-rec-3",
          artifact: %{kind: :command, text: "terminal test"},
          targets: %{node_ids: ["rec-host-3"]},
          timeout: %{wall_clock_ms: 60_000}
        })

      on_exit(fn ->
        case GenServer.whereis(Vigil.Core.Execution.Stream.via(group_id)) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end
      end)

      %Record{id: exec_id} = Repo.get_by!(Record, execution_group_id: group_id)

      # Manually mark it as ok (terminal) before recovery runs.
      Repo.get!(Record, exec_id)
      |> Ecto.Changeset.change(outcome: "ok", streaming_state: "closed")
      |> Repo.update!()

      Recovery.recover_in_flight()

      record = Repo.get!(Record, exec_id)
      assert record.outcome == "ok"
    end
  end
end
