defmodule Vigil.Integrations.SSH.Server do
  @moduledoc """
  Lifecycle process for a single SSH integration instance. It registers the
  instance for dispatch (`{:integration, id} → Vigil.Integrations.SSH`) and as
  the reload target (`{:config_server, id}`) in `Vigil.Plugin.Registry`, and
  holds the current config in memory.

  Reloads are applied **hot**: SSH capability calls are stateless reads that
  resolve the config file path and connection parameters on each call, so a
  config change takes effect on the next call without restarting the subtree.
  This deliberately sidesteps the restart-loses-new-config limitation noted for
  the no-op ConfigServer in #5 — and avoids a plugin→`vigil_core` dependency
  that re-reading config from the database would introduce.
  """

  use GenServer

  @registry Vigil.Plugin.Registry

  def start_link({integration_id, config}) do
    GenServer.start_link(__MODULE__, {integration_id, config})
  end

  @doc "Return the current config for an integration, or `{:error, :not_found}`."
  @spec get_config(Vigil.Plugin.integration_id()) :: {:ok, map()} | {:error, :not_found}
  def get_config(integration_id) do
    case Registry.lookup(@registry, {:config_server, integration_id}) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_config)}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init({integration_id, config}) do
    {:ok, _} =
      Registry.register(@registry, {:integration, integration_id}, Vigil.Integrations.SSH)

    {:ok, _} = Registry.register(@registry, {:config_server, integration_id}, __MODULE__)
    {:ok, %{integration_id: integration_id, config: config}}
  end

  @impl true
  def handle_call(:get_config, _from, state), do: {:reply, state.config, state}

  # Hot reload — replace config in place; the next capability call uses it.
  def handle_call({:reload, new_config}, _from, state) do
    {:reply, :hot, %{state | config: new_config}}
  end
end
