defmodule Vigil.Core.Journal do
  @moduledoc """
  Journal context: local PostgreSQL entries (executions + manual notes).

  External events (Puppet, monitoring, cloud) are never stored here; they are
  fetched on-demand at render time per design §7 (fetch-on-demand decision).
  """

  import Ecto.Query

  alias Vigil.Core.Journal.Entry
  alias Vigil.Repo

  defdelegate create(principal, attrs), to: Vigil.Core.Journal.Notes
  defdelegate update(principal, entry_id, changes), to: Vigil.Core.Journal.Notes
  defdelegate delete(principal, entry_id), to: Vigil.Core.Journal.Notes
  defdelegate revisions(entry_id), to: Vigil.Core.Journal.Notes

  @doc "Create one journal entry for a completed execution target (design §7.8)."
  def create_execution_entry(attrs) do
    result =
      %Entry{}
      |> Entry.execution_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        msg = {:journal_entry_created, entry}
        Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:node:#{entry.node_id}", msg)
        Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:global", msg)
        {:ok, entry}

      error ->
        error
    end
  end

  @doc "Per-node journal entries from local Postgres (design §7.6.1), ordered by occurred_at DESC."
  def local_entries(node_id, filters) do
    from(e in Entry, where: e.node_id == ^node_id)
    |> apply_filters(filters)
    |> order_by([e], desc: e.occurred_at)
    |> Repo.all()
  end

  @doc "Global journal entries from local Postgres (design §7.6.4), ordered by occurred_at DESC."
  def local_entries_global(filters) do
    from(e in Entry)
    |> apply_filters(filters)
    |> order_by([e], desc: e.occurred_at)
    |> Repo.all()
  end

  defp apply_filters(query, filters) do
    query
    |> exclude_deleted()
    |> filter_entry_type(filters[:entry_type])
    |> filter_severity(filters[:severity])
    |> filter_time_range(filters[:time_range])
    |> filter_node(filters[:node_id])
    |> filter_nodes(filters[:node_ids])
  end

  defp exclude_deleted(q), do: from(e in q, where: is_nil(e.deleted_at))

  defp filter_entry_type(q, nil), do: q
  defp filter_entry_type(q, t), do: from(e in q, where: e.entry_type == ^t)

  defp filter_severity(q, nil), do: q
  defp filter_severity(q, s), do: from(e in q, where: e.severity == ^s)

  defp filter_time_range(q, nil), do: q
  defp filter_time_range(q, {from, nil}), do: from(e in q, where: e.occurred_at >= ^from)
  defp filter_time_range(q, {from, to}), do: from(e in q, where: e.occurred_at >= ^from and e.occurred_at <= ^to)

  defp filter_node(q, nil), do: q
  defp filter_node(q, node_id), do: from(e in q, where: e.node_id == ^node_id)

  defp filter_nodes(q, nil), do: q
  defp filter_nodes(q, []), do: q
  defp filter_nodes(q, ids), do: from(e in q, where: e.node_id in ^ids)
end
