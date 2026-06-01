defmodule Vigil.Core.Execution.Record do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # outcome values: "running" | "ok" | "failed" | "timed_out" |
  #                 "aborted_by_restart" | "failed_to_start"
  # streaming_state values: "live" | "closed"

  schema "executions" do
    field :integration_id, :string
    field :node_id, :string
    field :artifact, :map
    field :outcome, :string, default: "running"
    field :exit_status, :integer
    field :transcript, :binary
    field :transcript_meta, :map, default: %{}
    field :streaming_state, :string, default: "live"
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :duration_ms, :integer

    belongs_to :execution_group, Vigil.Core.Execution.Group,
      foreign_key: :execution_group_id,
      type: :binary_id
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :execution_group_id,
      :integration_id,
      :node_id,
      :artifact,
      :outcome,
      :exit_status,
      :transcript,
      :transcript_meta,
      :streaming_state,
      :started_at,
      :ended_at,
      :duration_ms
    ])
    |> validate_required([:execution_group_id, :integration_id, :node_id, :artifact])
  end

  def finalize_changeset(record, %{exit_status: exit_status, duration_ms: duration_ms}, transcript) do
    outcome = if exit_status == 0, do: "ok", else: "failed"

    change(record,
      outcome: outcome,
      exit_status: exit_status,
      duration_ms: duration_ms,
      transcript: transcript,
      streaming_state: "closed",
      ended_at: DateTime.utc_now()
    )
  end
end
