defmodule Vigil.Core.RBAC.Role do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "roles" do
    field(:tenant_id, :binary_id)
    field(:name, :string)
    field(:description, :string)
    field(:built_in, :boolean, default: false)

    has_many(:role_permissions, Vigil.Core.RBAC.RolePermission)
    has_many(:user_roles, Vigil.Core.RBAC.UserRole)

    timestamps(type: :utc_datetime_usec)
  end

  @default_tenant_id "00000000-0000-0000-0000-000000000000"

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:tenant_id, :name, :description, :built_in])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :roles_tenant_id_name_index)
    |> put_default_tenant()
  end

  defp put_default_tenant(changeset) do
    if get_field(changeset, :tenant_id),
      do: changeset,
      else: put_change(changeset, :tenant_id, @default_tenant_id)
  end
end
