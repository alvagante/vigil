defmodule Vigil.Core.Inventory.LinkConflict do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "link_conflicts" do
    field :tenant_id, :binary_id
    field :observation, :map
    field :candidates, :map
    field :detected_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :resolution, :map
  end

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :observation, :candidates, :detected_at])
    |> put_defaults()
    |> validate_required([:observation, :candidates])
  end

  defp put_defaults(cs) do
    default_tenant = "00000000-0000-0000-0000-000000000000"

    cs
    |> put_change(:tenant_id, get_field(cs, :tenant_id) || default_tenant)
    |> put_change(:detected_at, get_field(cs, :detected_at) || DateTime.utc_now())
  end
end
