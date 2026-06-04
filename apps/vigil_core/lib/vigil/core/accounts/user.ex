defmodule Vigil.Core.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder, only: [:id, :username, :email, :display_name, :auth_source, :status]}

  schema "users" do
    field(:tenant_id, :binary_id)
    field(:username, :string)
    field(:email, :string)
    field(:display_name, :string)
    field(:password_hash, :string)
    field(:auth_source, :string, default: "local")
    field(:external_subject, :string)
    field(:status, :string, default: "active")
    field(:is_break_glass, :boolean)
    field(:last_login_at, :utc_datetime_usec)

    field(:password, :string, virtual: true)

    timestamps(type: :utc_datetime_usec)
  end

  @min_password_length 12

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :display_name, :password])
    |> validate_required([:username, :password])
    |> validate_length(:username, min: 2, max: 160)
    |> validate_length(:password, min: @min_password_length)
    |> unique_constraint(:username, name: :users_tenant_id_username_index)
    |> hash_password()
  end

  defp hash_password(%{valid?: false} = changeset), do: changeset

  defp hash_password(changeset) do
    case fetch_change(changeset, :password) do
      {:ok, password} ->
        changeset
        |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
        |> delete_change(:password)

      :error ->
        changeset
    end
  end
end
