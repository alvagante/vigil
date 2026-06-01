defmodule Vigil.Repo.Migrations.CreateExecutions do
  use Ecto.Migration

  def change do
    create table(:execution_groups, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :integration_id, :string, null: false
      add :artifact, :map, null: false
      add :intended_targets, :map, null: false, default: %{}
      add :dispatched_count, :integer, null: false, default: 0
      add :denied_count, :integer, null: false, default: 0
      add :submitted_by, :string
      add :submitted_at, :utc_datetime_usec, null: false
    end

    create index(:execution_groups, [:integration_id])
    create index(:execution_groups, [:submitted_at])

    create table(:executions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :execution_group_id,
          references(:execution_groups, type: :uuid, on_delete: :delete_all),
          null: false

      add :integration_id, :string, null: false
      add :node_id, :string, null: false
      add :artifact, :map, null: false
      add :outcome, :string, null: false, default: "running"
      add :exit_status, :integer
      # stored as gzipped binary on completion; raw iodata while live
      add :transcript, :binary
      add :transcript_meta, :map, null: false, default: %{}
      add :streaming_state, :string, null: false, default: "live"
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :duration_ms, :integer
    end

    create index(:executions, [:execution_group_id])
    create index(:executions, [:node_id])
    create index(:executions, [:integration_id])
    create index(:executions, [:outcome])
  end
end
