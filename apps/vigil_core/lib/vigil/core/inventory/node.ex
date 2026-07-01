defmodule Vigil.Core.Inventory.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "nodes" do
    field :tenant_id, :binary_id
    field :canonical_name, :string
    field :identity_attrs, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :lifecycle_state, :string, default: "active"
    field :unreported_since, :utc_datetime_usec
    field :decommissioned_at, :utc_datetime_usec
    field :decommissioned_by, :binary_id
    field :decommission_reason, :string
    field :metadata, :map, default: %{}

    has_many :node_sources, Vigil.Core.Inventory.NodeSource
  end

  @valid_states ~w(active unreported decommissioned)

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :canonical_name, :identity_attrs, :first_seen_at, :last_seen_at, :metadata])
    |> put_defaults()
    |> validate_required([:canonical_name, :identity_attrs])
    |> unique_constraint(:canonical_name, name: :nodes_tenant_id_canonical_name_index)
  end

  def lifecycle_changeset(node, state) when state in @valid_states do
    now = DateTime.utc_now()

    changes =
      case state do
        "unreported" -> %{lifecycle_state: "unreported", unreported_since: now, last_seen_at: now}
        "active" -> %{lifecycle_state: "active", unreported_since: nil, last_seen_at: now}
        "decommissioned" -> %{lifecycle_state: "decommissioned", decommissioned_at: now}
      end

    cast(node, changes, Map.keys(changes))
  end

  def decommission_changeset(node, user_id, reason) do
    now = DateTime.utc_now()

    cast(node, %{
      lifecycle_state: "decommissioned",
      decommissioned_at: now,
      decommissioned_by: user_id,
      decommission_reason: reason
    }, [:lifecycle_state, :decommissioned_at, :decommissioned_by, :decommission_reason])
  end

  defp put_defaults(cs) do
    now = DateTime.utc_now()
    default_tenant = "00000000-0000-0000-0000-000000000000"

    cs
    |> put_change(:tenant_id, get_field(cs, :tenant_id) || default_tenant)
    |> put_change(:first_seen_at, get_field(cs, :first_seen_at) || now)
    |> put_change(:last_seen_at, get_field(cs, :last_seen_at) || now)
    |> put_change(:lifecycle_state, get_field(cs, :lifecycle_state) || "active")
    |> put_change(:identity_attrs, get_field(cs, :identity_attrs) || %{})
    |> put_change(:metadata, get_field(cs, :metadata) || %{})
  end
end
