defmodule Vigil.DataCase do
  @moduledoc """
  DataCase template for tests that interact with the database.
  Uses the SQL sandbox so each test runs in an isolated transaction.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Vigil.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Vigil.DataCase
    end
  end

  setup tags do
    Vigil.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Vigil.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
