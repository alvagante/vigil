defmodule Vigil.Core.Audit do
  @moduledoc """
  Audit trail writer. Implements the audit-first ordering pattern (RBAC-305):
  `write_pending/3` inserts inside the same DB transaction as the triggering
  action; `finalize/2` transitions the entry to its terminal result after the
  side effect is initiated, outside the transaction.

  Actor routing:
  - `%User{}` struct  → `actor_user_id` (FK to users)
  - bare map / string → `actor_label`   (FK-free fallback for non-persisted principals)
  - `nil`             → both nil (system events)
  """

  alias Vigil.Core.Accounts.User
  alias Vigil.Core.Audit.Entry
  alias Vigil.Repo

  @type actor :: User.t() | %{id: term()} | nil
  @type result_atom :: :success | :denied | :failure | :error

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Inserts an `audit_entries` row with `result: "pending"`.

  Call this inside a `Repo.transaction/1` alongside the action's source-of-truth
  write, so both land atomically or neither does.

  Options: `target_kind`, `target_id`, `params`, `correlation_id`, `request_meta`.
  """
  @spec write_pending(actor(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def write_pending(actor, action, opts \\ []) do
    attrs = build_attrs(actor, action, "pending", nil, opts)

    %Entry{}
    |> Entry.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Inserts an `audit_entries` row already in a terminal state.

  Use for actions where there is no pending phase (e.g., auth events that
  complete synchronously, or fully-denied submissions).

  Options: same as `write_pending/3`.
  """
  @spec write_finalized(actor(), String.t(), result_atom(), keyword()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def write_finalized(actor, action, result, opts \\ []) when is_atom(result) do
    now = DateTime.utc_now()
    attrs = build_attrs(actor, action, to_string(result), now, opts)

    %Entry{}
    |> Entry.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Transitions a `pending` entry to a terminal result.

  Returns `{:error, :already_finalized}` if the entry is not in `pending` state.
  """
  @spec finalize(Entry.t(), result_atom()) :: {:ok, Entry.t()} | {:error, :already_finalized}
  def finalize(%Entry{result: "pending"} = entry, result) when is_atom(result) do
    now = DateTime.utc_now()

    entry
    |> Entry.finalize_changeset(to_string(result), now)
    |> Repo.update()
  end

  def finalize(%Entry{}, _result), do: {:error, :already_finalized}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_attrs(actor, action, result, finalized_at, opts) do
    {actor_user_id, actor_label} = resolve_actor(actor)

    %{
      occurred_at: DateTime.utc_now(),
      actor_user_id: actor_user_id,
      actor_label: actor_label,
      action: action,
      target_kind: opts[:target_kind],
      target_id: to_string_or_nil(opts[:target_id]),
      params: normalize_map(opts[:params]),
      result: result,
      correlation_id: opts[:correlation_id],
      request_meta: normalize_map(opts[:request_meta]),
      finalized_at: finalized_at
    }
  end

  # JSON round-trip normalizes atom keys to strings, matching DB read behavior.
  defp normalize_map(nil), do: %{}
  defp normalize_map(map), do: Jason.decode!(Jason.encode!(map))

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp resolve_actor(%User{id: id}), do: {id, nil}
  defp resolve_actor(%{id: id}), do: {nil, to_string(id)}
  defp resolve_actor(nil), do: {nil, nil}
end
