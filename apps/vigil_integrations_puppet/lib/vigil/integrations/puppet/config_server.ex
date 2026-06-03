defmodule Vigil.Integrations.Puppet.ConfigServer do
  @moduledoc """
  Lifecycle process for a single Puppet integration instance.

  Registers the instance under `{:integration, integration_id}` in
  `Vigil.Plugin.Registry` (so the dispatcher can resolve it) and under
  `{:config_server, integration_id}` (so capability implementations can read
  the current config). Holds the config in process state for hot reloads.
  """

  use GenServer

  @registry Vigil.Plugin.Registry

  def start_link({integration_id, config}) do
    GenServer.start_link(__MODULE__, {integration_id, config})
  end

  @spec get_config(Vigil.Plugin.integration_id()) :: {:ok, map()} | {:error, :not_found}
  def get_config(integration_id) do
    case Registry.lookup(@registry, {:config_server, integration_id}) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_config)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init({integration_id, config}) do
    {:ok, _} =
      Registry.register(@registry, {:integration, integration_id}, Vigil.Integrations.Puppet)

    {:ok, _} = Registry.register(@registry, {:config_server, integration_id}, nil)
    {:ok, %{integration_id: integration_id, config: config}}
  end

  @impl GenServer
  def handle_call(:get_config, _from, state), do: {:reply, state.config, state}

  def handle_call({:reload, new_config}, _from, state) do
    {:reply, :hot, %{state | config: new_config}}
  end
end
