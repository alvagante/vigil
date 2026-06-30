defmodule Vigil.Core.Journal.Notes do
  import Ecto.Query

  alias Vigil.Core.Journal.{Entry, NoteRevision}
  alias Vigil.Repo

  def create(principal, %{node_id: node_id} = attrs) do
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

  def revisions(entry_id) do
    from(r in NoteRevision,
      where: r.journal_entry_id == ^entry_id,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  defp build_detail(%{detail: detail, tags: tags}) when is_map(detail),
    do: Map.put(detail, "tags", tags)

  defp build_detail(%{tags: tags}), do: %{"tags" => tags}
  defp build_detail(%{detail: detail}) when is_map(detail), do: detail
  defp build_detail(_), do: nil
end
