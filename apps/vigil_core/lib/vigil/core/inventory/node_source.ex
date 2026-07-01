defmodule Vigil.Core.Inventory.NodeSource do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "node_sources" do
    belongs_to :node, Vigil.Core.Inventory.Node
    field :integration_id, :string
    field :plugin_id, :string
    field :source_identity, :map, default: %{}
    field :status, :string, default: "active"
    field :groups, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
  end

  def upsert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:node_id, :integration_id, :plugin_id, :source_identity, :status, :groups, :last_seen_at, :metadata])
    |> validate_required([:node_id, :integration_id])
    |> put_last_seen()
    |> unique_constraint(:integration_id, name: :node_sources_node_id_integration_id_index)
  end

  defp put_last_seen(cs) do
    put_change(cs, :last_seen_at, get_field(cs, :last_seen_at) || DateTime.utc_now())
  end
end
