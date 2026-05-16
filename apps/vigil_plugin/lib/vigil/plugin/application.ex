defmodule Vigil.Plugin.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Vigil.Plugin.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Vigil.Integrations.Supervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Vigil.Plugin.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
