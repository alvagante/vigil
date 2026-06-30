defmodule Vigil.Integrations.Ansible.Server do
  @moduledoc """
  Lifecycle process for a single Ansible integration instance.

  Registers in `Vigil.Plugin.Registry` for dispatch and config access,
  holds the current config in process state for hot reloads, and tracks
  the concurrent-execution slot count.
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

  @spec acquire_slot(Vigil.Plugin.integration_id(), pos_integer()) ::
          :ok | {:error, :at_capacity}
  def acquire_slot(integration_id, max_concurrency) do
    case Registry.lookup(@registry, {:config_server, integration_id}) do
      [{pid, _}] -> GenServer.call(pid, {:acquire_slot, max_concurrency})
      [] -> {:error, :not_found}
    end
  end

  @spec release_slot(Vigil.Plugin.integration_id()) :: :ok
  def release_slot(integration_id) do
    case Registry.lookup(@registry, {:config_server, integration_id}) do
      [{pid, _}] -> GenServer.call(pid, :release_slot)
      [] -> :ok
    end
  end

  @impl GenServer
  def init({integration_id, config}) do
    {:ok, _} =
      Registry.register(@registry, {:integration, integration_id}, Vigil.Integrations.Ansible)

    {:ok, _} = Registry.register(@registry, {:config_server, integration_id}, nil)

    {:ok, %{integration_id: integration_id, config: config, active_executions: 0}}
  end

  @impl GenServer
  def handle_call(:get_config, _from, state), do: {:reply, state.config, state}

  def handle_call({:reload, new_config}, _from, state) do
    {:reply, :hot, %{state | config: new_config}}
  end

  def handle_call({:acquire_slot, max}, _from, state) do
    if state.active_executions < max do
      {:reply, :ok, %{state | active_executions: state.active_executions + 1}}
    else
      {:reply, {:error, :at_capacity}, state}
    end
  end

  def handle_call(:release_slot, _from, state) do
    count = max(0, state.active_executions - 1)
    {:reply, :ok, %{state | active_executions: count}}
  end
end
