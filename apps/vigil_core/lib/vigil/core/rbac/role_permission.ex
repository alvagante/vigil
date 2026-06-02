defmodule Vigil.Core.RBAC.RolePermission do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_permissions" do
    belongs_to :role, Vigil.Core.RBAC.Role

    field :action, :string
    field :integration_id, :binary_id
    field :target_selector, :map
    field :command_policy, :map

    field :inserted_at, :utc_datetime_usec
  end

  def changeset(rp, attrs) do
    rp
    |> cast(attrs, [:role_id, :action, :integration_id, :target_selector, :command_policy])
    |> validate_required([:role_id, :action])
    |> put_change(:inserted_at, DateTime.utc_now())
  end
end
