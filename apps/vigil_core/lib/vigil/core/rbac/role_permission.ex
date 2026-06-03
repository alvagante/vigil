defmodule Vigil.Core.RBAC.RolePermission do
  use Ecto.Schema
  import Ecto.Changeset

  alias Vigil.Core.RBAC.GlobPolicy

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
    |> validate_command_policy()
    |> put_change(:inserted_at, DateTime.utc_now())
  end

  defp validate_command_policy(changeset) do
    case get_change(changeset, :command_policy) do
      nil ->
        changeset

      %{"allow" => allow, "deny" => deny} ->
        patterns = List.wrap(allow) ++ List.wrap(deny)

        invalid =
          Enum.filter(patterns, fn p ->
            is_binary(p) &&
              match?({:error, _}, try_compile(p))
          end)

        if invalid == [] do
          changeset
        else
          add_error(changeset, :command_policy, "contains invalid glob patterns: #{inspect(invalid)}")
        end

      _ ->
        add_error(changeset, :command_policy, "must have \"allow\" and \"deny\" lists")
    end
  end

  defp try_compile(pattern) do
    {:ok, GlobPolicy.compile!(pattern)}
  rescue
    ArgumentError -> {:error, :invalid}
  end
end
