defmodule Vigil.Plugin.Dispatcher do
  @moduledoc """
  The single entry point for capability calls (design §3.3). Plugins are never
  called directly; every call resolves the target integration through the
  `Vigil.Plugin.Registry` and routes to the registered plugin module.

  Cache wiring: results are stored in `Vigil.Core.Cache` (ADR-0006). A cache
  hit returns the stored `%Result{}` with `freshness: :cached`, skipping the
  upstream plugin call entirely. Errors are never cached. RBAC target-scope
  filtering is applied by callers after the returned result, not here.
  """

  alias Vigil.Core.Cache
  alias Vigil.Plugin.{Error, Result}

  # 5-minute default TTL. Override via opts %{ttl_ms: integer}.
  @default_ttl_ms 300_000

  @doc """
  Resolve `integration_id` to its plugin module and invoke `action` for the
  given `capability`, returning the plugin's typed result.

  On cache hit the result is returned immediately with `freshness: :cached`.
  On cache miss the plugin is called; the result is cached and returned with
  `freshness: :live`.
  """
  @spec call(Vigil.Plugin.integration_id(), Vigil.Plugin.capability(), atom(), map(), map()) ::
          {:ok, Result.t()} | {:error, term()}
  def call(integration_id, capability, action, args, opts \\ %{}) do
    ttl_ms = Map.get(opts, :ttl_ms, @default_ttl_ms)

    case Cache.fetch(integration_id, capability, action, args, ttl_ms, fn ->
           upstream(integration_id, action, args)
         end) do
      {:ok, %Cache.Entry{data: %Result{} = result}, :miss} ->
        {:ok, result}

      {:ok, %Cache.Entry{data: %Result{} = result}, :hit} ->
        {:ok, %Result{result | freshness: :cached}}

      {:error, _} = err ->
        err
    end
  end

  # Resolve the plugin and invoke the action upstream.
  defp upstream(integration_id, action, args) do
    case Registry.lookup(Vigil.Plugin.Registry, {:integration, integration_id}) do
      [{_pid, plugin_module}] ->
        case apply(plugin_module, action, [integration_id, args]) do
          {:ok, %Result{} = result} -> {:ok, result}
          {:error, _} = err -> err
        end

      [] ->
        {:error,
         %Error{
           category: :configuration,
           message: "no plugin registered for integration #{inspect(integration_id)}",
           retriable?: false
         }}
    end
  end
end
