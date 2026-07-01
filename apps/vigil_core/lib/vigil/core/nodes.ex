defmodule Vigil.Core.Nodes do
  @moduledoc """
  Persistence operations for canonical node records (design §4.3.1, ADR-0002).

  All writes go through this context; the Linker is the primary caller.
  Never call Repo directly for node identity — this module is the single
  authority on lifecycle transitions and source attribution.
  """

  import Ecto.Query

  alias Vigil.Core.Inventory.{LinkConflict, Node, NodeSource}
  alias Vigil.Repo

  @doc """
  Insert a new canonical node.  Returns `{:ok, node}` on success,
  `{:error, changeset}` on validation failure or duplicate.
  """
  @spec insert(map()) :: {:ok, Node.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    attrs
    |> Node.insert_changeset()
    |> Repo.insert()
  end

  @doc """
  Upsert the source attribution record for `(node_id, integration_id)`.
  On conflict (same unique pair), updates plugin_id, source_identity,
  status, groups, and last_seen_at.
  """
  @spec upsert_source(map()) :: {:ok, NodeSource.t()} | {:error, Ecto.Changeset.t()}
  def upsert_source(attrs) do
    cs = NodeSource.upsert_changeset(attrs)

    Repo.insert(cs,
      on_conflict: {:replace, [:plugin_id, :source_identity, :status, :groups, :last_seen_at]},
      conflict_target: [:node_id, :integration_id]
    )
  end

  @doc """
  Remove a single integration's attribution for a node.
  Returns `{:ok, %{remaining_sources: non_neg_integer()}}`.
  """
  @spec remove_source(binary(), binary()) :: {:ok, %{remaining_sources: non_neg_integer()}}
  def remove_source(node_id, integration_id) do
    Repo.delete_all(
      from(s in NodeSource,
        where: s.node_id == ^node_id and s.integration_id == ^integration_id
      )
    )

    count = Repo.one(from(s in NodeSource, where: s.node_id == ^node_id, select: count()))
    {:ok, %{remaining_sources: count}}
  end

  @doc """
  Returns the `MapSet` of node_ids currently attributed to `integration_id`.
  Used by `detect_unreported/2` to find nodes that dropped off.
  """
  @spec ids_currently_attributed_to(binary()) :: MapSet.t(binary())
  def ids_currently_attributed_to(integration_id) do
    from(s in NodeSource,
      where: s.integration_id == ^integration_id,
      select: s.node_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Stream all active and unreported nodes for index rebuild at startup.
  Decommissioned nodes are excluded — their identity claims have been released (DM-1107).
  """
  @spec stream_active_and_unreported() :: Enumerable.t()
  def stream_active_and_unreported do
    from(n in Node,
      where: n.lifecycle_state in ["active", "unreported"],
      select: %{id: n.id, identity_attrs: n.identity_attrs}
    )
    |> Repo.all()
  end

  @doc """
  Transition a node to a new lifecycle state.
  Valid transitions: active ↔ unreported; explicit decommission uses `decommission/3`.
  """
  @spec transition_lifecycle(binary(), atom()) :: {:ok, Node.t()} | {:error, any()}
  def transition_lifecycle(node_id, state) when state in [:active, :unreported] do
    state_str = Atom.to_string(state)

    case Repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      node -> node |> Node.lifecycle_changeset(state_str) |> Repo.update()
    end
  end

  @doc """
  Explicit admin decommission. Transitions to `:decommissioned`, records the
  operator and reason. Does NOT release ETS claims — the Linker's
  `handle_call({:decommission, ...})` does that before calling here.
  """
  @spec decommission(binary(), binary(), String.t() | nil) :: {:ok, Node.t()} | {:error, any()}
  def decommission(node_id, user_id, reason \\ nil) do
    case Repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      node -> node |> Node.decommission_changeset(user_id, reason) |> Repo.update()
    end
  end

  @doc "Record a detected ambiguity when multiple node_ids match one observation."
  @spec insert_conflict(map()) :: {:ok, LinkConflict.t()} | {:error, Ecto.Changeset.t()}
  def insert_conflict(attrs) do
    attrs
    |> LinkConflict.insert_changeset()
    |> Repo.insert()
  end

  @doc "Return the node with the given id, or nil."
  @spec get(binary()) :: Node.t() | nil
  def get(id), do: Repo.get(Node, id)
end
