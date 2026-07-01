defmodule Vigil.Core.Journal.Notes do
  import Ecto.Query

  alias Vigil.Core.Audit
  alias Vigil.Core.Journal.{Entry, NoteRevision}
  alias Vigil.Repo

  def create(principal, %{node_id: node_id} = attrs) do
    result =
      %Entry{}
      |> Entry.note_changeset(%{
        node_id: node_id,
        summary: attrs[:summary] || attrs["summary"],
        detail: build_detail(attrs),
        severity: "notice",
        author_user_id: principal.id,
        occurred_at: attrs[:occurred_at] || DateTime.utc_now()
      })
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        broadcast_entry_created(entry)
        {:ok, entry}

      error ->
        error
    end
  end

  def update(principal, entry_id, changes) do
    entry = Repo.get!(Entry, entry_id)

    if entry.author_user_id != principal.id do
      {:error, :unauthorized}
    else
      Repo.transaction(fn ->
        Repo.insert!(%NoteRevision{
          journal_entry_id: entry.id,
          editor_user_id: principal.id,
          previous_summary: entry.summary,
          previous_detail: entry.detail
        })

        entry
        |> Entry.note_changeset(changes)
        |> Repo.update!()
      end)
    end
  end

  def delete(principal, entry_id) do
    entry = Repo.get!(Entry, entry_id)

    if entry.author_user_id != principal.id do
      Audit.write_finalized(principal, "journal.note.delete", :denied,
        target_kind: "journal_entry",
        target_id: entry_id
      )

      {:error, :unauthorized}
    else
      result =
        entry
        |> Entry.soft_delete_changeset()
        |> Repo.update()

      case result do
        {:ok, deleted} ->
          Audit.write_finalized(principal, "journal.note.delete", :success,
            target_kind: "journal_entry",
            target_id: entry_id
          )

          broadcast_entry_deleted(deleted)
          {:ok, deleted}

        error ->
          error
      end
    end
  end

  def revisions(entry_id) do
    from(r in NoteRevision,
      where: r.journal_entry_id == ^entry_id,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  defp broadcast_entry_created(entry) do
    msg = {:journal_entry_created, entry}
    Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:node:#{entry.node_id}", msg)
    Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:global", msg)
  end

  defp broadcast_entry_deleted(entry) do
    msg = {:journal_entry_deleted, entry}
    Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:node:#{entry.node_id}", msg)
    Phoenix.PubSub.broadcast(Vigil.PubSub, "journal:global", msg)
  end

  defp build_detail(%{detail: detail, tags: tags}) when is_map(detail),
    do: Map.put(detail, "tags", tags)

  defp build_detail(%{tags: tags}), do: %{"tags" => tags}
  defp build_detail(%{detail: detail}) when is_map(detail), do: detail
  defp build_detail(_), do: nil
end
