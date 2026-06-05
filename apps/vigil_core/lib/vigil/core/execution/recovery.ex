defmodule Vigil.Core.Execution.Recovery do
  @moduledoc """
  Startup recovery for in-flight executions that were interrupted by a restart.

  `recover_in_flight/0` is called during application start (see Application).
  It scans `executions` for rows still in `outcome: "running"` — which means
  the platform shut down before the Stream GenServer could persist the final
  transcript — and promotes whatever partial transcript exists into the final
  transcript, then marks the record as `aborted_by_restart` (design §6.2.8).
  """

  import Ecto.Query

  alias Vigil.Core.Execution.Record
  alias Vigil.Repo

  @abort_marker "\n[EXECUTION ABORTED: platform restarted before this run completed]\n"

  @doc """
  Recovers all `running` execution records left over from a previous process.
  Safe to call on a clean restart (no-op when there are no orphaned rows).
  """
  def recover_in_flight do
    orphans = Repo.all(from(r in Record, where: r.outcome == "running"))

    Enum.each(orphans, &recover_record/1)
  end

  defp recover_record(record) do
    transcript =
      case record.partial_transcript do
        nil -> :zlib.gzip(@abort_marker)
        gzipped -> rebuild_transcript(gzipped)
      end

    record
    |> Ecto.Changeset.change(
      outcome: "aborted_by_restart",
      streaming_state: "closed",
      transcript: transcript,
      partial_transcript: nil,
      ended_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp rebuild_transcript(gzipped) do
    raw = :zlib.gunzip(gzipped)
    :zlib.gzip(raw <> @abort_marker)
  end
end
