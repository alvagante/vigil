defmodule Vigil.Plugin.Dispatcher do
  @moduledoc """
  The single entry point for capability calls (design §3.3). Plugins are never
  called directly; every call resolves the target integration through the
  `Vigil.Plugin.Registry` and routes to the registered plugin module.

  Cross-cutting concerns (RBAC, circuit breaker, concurrency limiting, request
  coalescing, caching, deadline propagation) are layered onto this path by
  later work — see design §3.3. This module currently implements the
  resolve → route → typed-result core.
  """

  @doc """
  Resolve `integration_id` to its plugin module and invoke `action` for the
  given `capability`, returning the plugin's typed result.
  """
  @spec call(Vigil.Plugin.integration_id(), Vigil.Plugin.capability(), atom(), map(), map()) ::
          {:ok, Vigil.Plugin.Result.t()} | {:error, term()}
  def call(integration_id, _capability, action, args, _opts \\ %{}) do
    case Registry.lookup(Vigil.Plugin.Registry, {:integration, integration_id}) do
      [{_pid, plugin_module}] ->
        apply(plugin_module, action, [integration_id, args])

      [] ->
        {:error,
         %Vigil.Plugin.Error{
           category: :configuration,
           message: "no plugin registered for integration #{inspect(integration_id)}",
           retriable?: false
         }}
    end
  end
end
