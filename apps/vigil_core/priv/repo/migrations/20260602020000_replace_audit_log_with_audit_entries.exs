defmodule Vigil.Repo.Migrations.ReplaceAuditLogWithAuditEntries do
  use Ecto.Migration

  def up do
    drop table(:audit_log)

    create table(:audit_entries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, :uuid, null: false, default: fragment("'00000000-0000-0000-0000-000000000000'::uuid")
      add :occurred_at, :utc_datetime_usec, null: false
      add :actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :actor_label, :text
      add :action, :text, null: false
      add :target_kind, :text
      add :target_id, :text
      add :params, :map, null: false, default: %{}
      add :result, :text, null: false
      add :correlation_id, :text
      add :request_meta, :map, null: false, default: %{}
      add :finalized_at, :utc_datetime_usec
    end

    create index(:audit_entries, [:tenant_id, :actor_user_id, :occurred_at])
    create index(:audit_entries, [:tenant_id, :target_kind, :target_id, :occurred_at])
    create index(:audit_entries, [:tenant_id, :action, :occurred_at])
    create index(:audit_entries, [:result, :occurred_at], where: "result = 'pending'")

    create constraint(:audit_entries, :valid_result,
      check: "result IN ('pending', 'success', 'denied', 'failure', 'error')"
    )

    execute """
    CREATE OR REPLACE FUNCTION audit_entries_immutable()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.result != 'pending' THEN
        RAISE EXCEPTION 'audit_entries: finalized entry % is immutable', OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """,
    "DROP FUNCTION IF EXISTS audit_entries_immutable();"

    execute """
    CREATE TRIGGER audit_entries_immutable_tgr
    BEFORE UPDATE ON audit_entries
    FOR EACH ROW EXECUTE FUNCTION audit_entries_immutable();
    """,
    "DROP TRIGGER IF EXISTS audit_entries_immutable_tgr ON audit_entries;"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS audit_entries_immutable_tgr ON audit_entries;"
    execute "DROP FUNCTION IF EXISTS audit_entries_immutable();"

    drop table(:audit_entries)

    create table(:audit_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :occurred_at, :utc_datetime_usec, null: false
      add :user_id, :string
      add :action, :string, null: false
      add :target, :map, null: false, default: %{}
      add :outcome, :string, null: false, default: "submitted"
    end

    create index(:audit_log, [:user_id])
    create index(:audit_log, [:action])
    create index(:audit_log, [:occurred_at])
  end
end
