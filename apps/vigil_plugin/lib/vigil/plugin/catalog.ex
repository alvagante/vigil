defmodule Vigil.Plugin.Catalog do
  @moduledoc """
  Discovers available plugin types and maps `plugin_id` strings to their
  implementing modules (design §3.2.1, scoped to the minimum needed by #5).

  Discovery scans loaded OTP applications for those that declare `:vigil_plugin`
  in their `application.env`. Full OTP-app-env discovery was explicitly deferred
  to issue #6 (first real plugin); for now the scan is the minimum viable path.

  Modules may also be registered manually via `register/2`, which is useful in
  test environments where the plugin OTP app is not started as a separate BEAM
  application (e.g., the no-op reference plugin compiled in `:test` env).
  """

  use GenServer
  require Logger

  @name __MODULE__

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Return `{:ok, module}` for the given `plugin_id`, or `{:error, :not_found}`."
  @spec lookup(String.t()) :: {:ok, module()} | {:error, :not_found}
  def lookup(plugin_id) do
    GenServer.call(@name, {:lookup, plugin_id})
  end

  @doc "Manually register a `plugin_id → module` mapping (useful in tests)."
  @spec register(String.t(), module()) :: :ok
  def register(plugin_id, module) do
    GenServer.call(@name, {:register, plugin_id, module})
  end

  @doc "Return all discovered `{plugin_id, module}` pairs."
  @spec all() :: [{String.t(), module()}]
  def all do
    GenServer.call(@name, :all)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(_opts) do
    catalog = discover_from_otp_apps()

    Logger.debug(
      "[Catalog] discovered #{map_size(catalog)} plugin type(s): #{inspect(Map.keys(catalog))}"
    )

    {:ok, catalog}
  end

  @impl GenServer
  def handle_call({:lookup, plugin_id}, _from, catalog) do
    case Map.fetch(catalog, plugin_id) do
      {:ok, mod} -> {:reply, {:ok, mod}, catalog}
      :error -> {:reply, {:error, :not_found}, catalog}
    end
  end

  def handle_call({:register, plugin_id, module}, _from, catalog) do
    {:reply, :ok, Map.put(catalog, plugin_id, module)}
  end

  def handle_call(:all, _from, catalog) do
    {:reply, Map.to_list(catalog), catalog}
  end

  ## Discovery

  defp discover_from_otp_apps do
    Application.loaded_applications()
    |> Enum.flat_map(fn {app, _desc, _vsn} ->
      case Application.get_env(app, :vigil_plugin) do
        nil -> []
        mod -> discovered_pair(app, mod)
      end
    end)
    |> Map.new()
  end

  # A plugin app declares its module via `env: [vigil_plugin: Mod]`. Guard
  # against a module that isn't loadable or doesn't implement the contract so a
  # single misconfigured plugin app can't take down platform boot.
  defp discovered_pair(app, mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :plugin_id, 0) do
      [{mod.plugin_id(), mod}]
    else
      Logger.warning(
        "[Catalog] app #{inspect(app)} declares vigil_plugin #{inspect(mod)} but it is not a usable plugin module; skipping"
      )

      []
    end
  end
end
