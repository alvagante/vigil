defmodule VigilWeb.DataCase do
  @moduledoc """
  DataCase for vigil_web tests that need database access.
  Delegates sandbox setup to the vigil_core DataCase helper.
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
end
