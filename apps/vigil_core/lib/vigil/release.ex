defmodule Vigil.Release do
  @moduledoc """
  Release tasks invoked from the assembled artefact, e.g.

      bin/vigil eval "Vigil.Release.migrate()"

  These run without Mix available, so they load the application and start the
  repos manually before running migrations.
  """

  @app :vigil_core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
