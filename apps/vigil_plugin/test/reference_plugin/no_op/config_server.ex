defmodule Vigil.Plugin.NoOp.ConfigServer do
  @moduledoc """
  Holds current config for a no-op integration instance and handles reload
  requests from `Vigil.Integrations.Manager` (design §2.4, §3.6).

  Fields classified as `reload: :hot` in the plugin schema are applied in-place
  without restarting the supervisor. Fields classified as `reload: :restart`
  (or with unspecified reload behaviour) trigger a `stop/2` so the supervisor
  restarts the subtree with the new config.
  """

  use GenServer
  require Logger

  alias Vigil.Plugin.{Schema, NoOp}

  def start_link({integration_id, config}) do
    GenServer.start_link(__MODULE__, {integration_id, config})
  end

  @doc "Return the current config held by this server."
  def get_config(integration_id) do
    with {:ok, pid} <- pid_for(integration_id), do: GenServer.call(pid, :get_config)
  end

  @doc """
  Apply a new config. Hot-updatable fields are applied immediately; if any
  changed field requires a restart, the server stops (supervisor will restart it).
  Returns `:hot` or `:restart` to indicate which path was taken.
  """
  def reload(integration_id, new_config) do
    with {:ok, pid} <- pid_for(integration_id), do: GenServer.call(pid, {:reload, new_config})
  end

  defp pid_for(integration_id) do
    case Registry.lookup(Vigil.Plugin.Registry, {:config_server, integration_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init({integration_id, config}) do
    {:ok, _} =
      Registry.register(
        Vigil.Plugin.Registry,
        {:config_server, integration_id},
        __MODULE__
      )

    {:ok, %{integration_id: integration_id, config: config}}
  end

  @impl GenServer
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl GenServer
  def handle_call({:reload, new_config}, _from, state) do
    schema = NoOp.config_schema()
    changed_fields = changed_field_names(state.config, new_config)
    reload_modes = reload_modes_for(schema, changed_fields)

    if Enum.any?(reload_modes, &(&1 == :restart || is_nil(&1))) do
      Logger.info("[noop:config_server] restart required for fields: #{inspect(changed_fields)}")
      {:stop, :reload, :restart, state}
    else
      Logger.info("[noop:config_server] hot reload for fields: #{inspect(changed_fields)}")
      {:reply, :hot, %{state | config: new_config}}
    end
  end

  defp changed_field_names(old_config, new_config) do
    all_keys = MapSet.union(MapSet.new(Map.keys(old_config)), MapSet.new(Map.keys(new_config)))

    Enum.filter(all_keys, fn k ->
      Map.get(old_config, k) != Map.get(new_config, k)
    end)
  end

  defp reload_modes_for(%Schema{fields: fields}, changed_names) do
    name_to_mode = Map.new(fields, fn f -> {f.name, f.reload} end)
    Enum.map(changed_names, fn name -> Map.get(name_to_mode, name) end)
  end
end
