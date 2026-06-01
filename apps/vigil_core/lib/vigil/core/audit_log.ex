defmodule Vigil.Core.AuditLog do
  @moduledoc """
  Minimal local audit log per the ROAD-104 carry-forward in issue #7.
  Records execution submissions with `{timestamp, user_id, action, target, outcome}`.
  This schema is replaced (or extended) by the proper audit writer in #8
  when RBAC infrastructure and full audit-first ordering land.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_log" do
    field :occurred_at, :utc_datetime_usec
    field :user_id, :string
    field :action, :string
    field :target, :map, default: %{}
    field :outcome, :string, default: "submitted"
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:occurred_at, :user_id, :action, :target, :outcome])
    |> validate_required([:occurred_at, :action])
  end
end
