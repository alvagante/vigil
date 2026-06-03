defmodule Vigil.Core.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Vigil.Repo,
      {Oban, Application.fetch_env!(:vigil_core, Oban)},
      {Phoenix.PubSub, name: Vigil.PubSub},
      {Finch, name: Vigil.Finch},
      Vigil.Telemetry.Supervisor,
      Vigil.Core.Supervisor,
      Vigil.Core.Execution.Supervisor,
      Vigil.Core.RBAC.PermissionCache,
      Vigil.Core.Cache.Server
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
