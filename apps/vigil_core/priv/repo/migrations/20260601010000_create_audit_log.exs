defmodule Vigil.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def change do
    create table(:audit_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :occurred_at, :utc_datetime_usec, null: false
      add :user_id, :string
      add :action, :string, null: false
      add :target, :map, null: false, default: %{}
      # "submitted" | "ok" | "failed" | "timed_out" | "denied"
      add :outcome, :string, null: false, default: "submitted"
    end

    create index(:audit_log, [:user_id])
    create index(:audit_log, [:action])
    create index(:audit_log, [:occurred_at])
  end
end
