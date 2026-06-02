defmodule Vigil.Core.RBAC.UserRole do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "user_roles" do
    field :user_id, :binary_id, primary_key: true
    field :role_id, :binary_id, primary_key: true
    field :source, :string, primary_key: true
    field :assigned_at, :utc_datetime_usec
    field :assigned_by, :binary_id

    belongs_to :user, Vigil.Core.Accounts.User, define_field: false
  end

  def changeset(ur, attrs) do
    ur
    |> cast(attrs, [:user_id, :role_id, :source, :assigned_at, :assigned_by])
    |> validate_required([:user_id, :role_id, :source, :assigned_at])
  end
end
