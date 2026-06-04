defmodule Vigil.Plugin.NoOp.Server do
  @moduledoc """
  Lifecycle process for a single no-op integration instance. On init it
  registers the instance under `{:integration, integration_id}` in
  `Vigil.Plugin.Registry` (so the dispatcher can resolve it) and holds the
  registration alive for the life of the subtree. `terminate/2` is the
  shutdown hook.
  """

  use GenServer

  def start_link({integration_id, config}) do
    GenServer.start_link(__MODULE__, {integration_id, config})
  end

  @impl GenServer
  def init({integration_id, config}) do
    {:ok, _} =
      Registry.register(Vigil.Plugin.Registry, {:integration, integration_id}, Vigil.Plugin.NoOp)

    {:ok, %{integration_id: integration_id, config: config}}
  end
end
