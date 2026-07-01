defmodule Vigil.Repo.Migrations.CreateInventoryNodes do
  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false
      add :canonical_name, :text, null: false

      # JSONB map of normalized identity attributes, e.g.
      # %{certname: "web-01.prod", fqdn: "web-01.prod.example.com", hostname: "web-01"}
      add :identity_attrs, :map, null: false, default: %{}

      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec

      # 'active' | 'unreported' | 'decommissioned'
      add :lifecycle_state, :text, null: false, default: "active"
      add :unreported_since, :utc_datetime_usec
      add :decommissioned_at, :utc_datetime_usec
      add :decommissioned_by, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :decommission_reason, :text

      add :metadata, :map, null: false, default: %{}
    end

    create constraint(:nodes, :lifecycle_state_values,
             check: "lifecycle_state IN ('active','unreported','decommissioned')"
           )

    create unique_index(:nodes, [:tenant_id, :canonical_name])
    create index(:nodes, [:tenant_id, :last_seen_at])
    create index(:nodes, [:tenant_id, :lifecycle_state])
    execute "CREATE INDEX nodes_identity_attrs_gin ON nodes USING GIN (identity_attrs)",
            "DROP INDEX nodes_identity_attrs_gin"

    # Per-integration source attribution
    create table(:node_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :integration_id, :text, null: false
      add :plugin_id, :text
      add :source_identity, :map, null: false, default: %{}

      # 'active' | 'unreported' — this source's own view
      add :status, :text, null: false, default: "active"
      add :groups, {:array, :text}, null: false, default: []
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
    end

    create unique_index(:node_sources, [:node_id, :integration_id])
    create index(:node_sources, [:integration_id])

    # Admin overrides: explicit link or unlink decisions
    create table(:manual_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false

      # 'link' (force merge) | 'unlink' (force separate)
      add :action, :text, null: false

      # JSONB identity fingerprints of the two subjects
      add :identity_a, :map, null: false
      add :identity_b, :map, null: false

      add :created_by, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :created_at, :utc_datetime_usec, null: false
      add :note, :text
    end

    create constraint(:manual_links, :manual_link_action_values,
             check: "action IN ('link','unlink')"
           )

    create index(:manual_links, [:tenant_id])
  end
end
