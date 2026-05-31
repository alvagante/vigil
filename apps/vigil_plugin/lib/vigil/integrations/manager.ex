defmodule Vigil.Integrations.Manager do
  @moduledoc """
  Bridges `Vigil.Core.IntegrationConfig` (persistence layer) and
  `Vigil.Integrations.Supervisor` (the DynamicSupervisor that owns running
  integration subtrees) per design §2.4.

  On startup it loads all enabled integrations from the database and spawns
  their subtrees. It then subscribes to the `"integration_lifecycle"` PubSub
  topic and reacts to enable/disable/config-update events.

  The initial DB load is done asynchronously via `handle_continue/2` so the
  GenServer starts cleanly even when the database is unavailable (e.g., during
  standalone `vigil_plugin` unit tests). A failed load logs a warning and leaves
  the Manager with an empty integration set; the next PubSub event or a future
  restart will re-attempt.
  """

  use GenServer
  require Logger

  alias Vigil.Plugin.{Catalog, Health}

  @dynamic_sup Vigil.Integrations.Supervisor
  @pubsub_name Vigil.PubSub
  @pubsub_topic "integration_lifecycle"

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer callbacks

  # State: %{id => %{supervisor_pid: pid, health_worker_pid: pid}}
  @impl GenServer
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub_name, @pubsub_topic)
    {:ok, %{}, {:continue, :load_integrations}}
  end

  @impl GenServer
  def handle_continue(:load_integrations, state) do
    try do
      enabled = Vigil.Core.IntegrationConfig.list_enabled()

      new_state =
        Enum.reduce(enabled, state, fn integration, acc ->
          start_integration(integration.id, integration.plugin_id, integration.config, acc)
        end)

      Logger.info("[Manager] loaded #{length(enabled)} enabled integration(s) from database")
      {:noreply, new_state}
    rescue
      e ->
        Logger.warning("[Manager] could not load integrations from database: #{Exception.message(e)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:integration_enabled, id}, state) do
    new_state =
      try do
        integration = Vigil.Core.IntegrationConfig.get!(id)
        start_integration(id, integration.plugin_id, integration.config, state)
      rescue
        e ->
          Logger.warning("[Manager] failed to start integration #{id}: #{Exception.message(e)}")
          state
      end

    {:noreply, new_state}
  end

  def handle_info({:integration_disabled, id}, state) do
    new_state = stop_integration(id, state)
    {:noreply, new_state}
  end

  def handle_info({:integration_config_updated, id, new_config}, state) do
    case Registry.lookup(Vigil.Plugin.Registry, {:config_server, id}) do
      [{pid, _}] ->
        GenServer.call(pid, {:reload, new_config})

      [] ->
        Logger.warning("[Manager] config_server not found for #{id}, ignoring reload")
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Manager] unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private helpers

  defp start_integration(id, plugin_id, config, state) do
    case Catalog.lookup(plugin_id) do
      {:ok, module} ->
        child_spec = module.child_spec({id, config})

        case DynamicSupervisor.start_child(@dynamic_sup, child_spec) do
          {:ok, sup_pid} ->
            hw_pid = start_health_worker(id, module)
            Logger.info("[Manager] started integration #{id} (plugin=#{plugin_id})")
            Map.put(state, id, %{supervisor_pid: sup_pid, health_worker_pid: hw_pid})

          {:error, {:already_started, _}} ->
            Logger.debug("[Manager] integration #{id} already running, skipping start")
            state

          {:error, reason} ->
            Logger.warning("[Manager] failed to start integration #{id}: #{inspect(reason)}")
            state
        end

      {:error, :not_found} ->
        Logger.warning("[Manager] unknown plugin_id=#{plugin_id} for integration #{id}")
        state
    end
  end

  defp start_health_worker(integration_id, plugin_module) do
    spec = Health.Worker.child_spec({integration_id, plugin_module, []})

    case DynamicSupervisor.start_child(@dynamic_sup, spec) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Logger.warning("[Manager] health worker start failed for #{integration_id}: #{inspect(reason)}")
        nil
    end
  end

  defp stop_integration(id, state) do
    case Map.pop(state, id) do
      {%{supervisor_pid: sup_pid, health_worker_pid: hw_pid}, new_state} ->
        if hw_pid && Process.alive?(hw_pid) do
          DynamicSupervisor.terminate_child(@dynamic_sup, hw_pid)
        end

        if sup_pid && Process.alive?(sup_pid) do
          DynamicSupervisor.terminate_child(@dynamic_sup, sup_pid)
        end

        Logger.info("[Manager] stopped integration #{id}")
        new_state

      {nil, state} ->
        Logger.warning("[Manager] tried to stop unknown integration #{id}")
        state
    end
  end
end
