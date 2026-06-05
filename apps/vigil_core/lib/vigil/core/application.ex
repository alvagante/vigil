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
      {Registry, keys: :unique, name: Vigil.Core.Execution.Registry},
      {Finch, name: Vigil.Finch},
      Vigil.Telemetry.Supervisor,
      Vigil.Core.Supervisor,
      Vigil.Core.Execution.Supervisor,
      Vigil.Core.RBAC.PermissionCache,
      Vigil.Core.Cache.Server,
      Vigil.Core.Cache.Janitor
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one)
    Vigil.Core.Execution.Recovery.recover_in_flight()
    result
  end
end
