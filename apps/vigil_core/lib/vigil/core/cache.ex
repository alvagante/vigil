defmodule Vigil.Core.Cache do
  @moduledoc """
  Shared unfiltered integration cache (ADR-0006, design §5.3).

  Cache keys do not include principal identity — results are shared across
  all callers for the same {integration_id, capability, action, args}. RBAC
  target-scope filtering is applied by callers after cache lookup.

  Reads are served directly from ETS (no GenServer round-trip). Writes and
  invalidations go through `Cache.Server`.
  """

  alias Vigil.Core.Cache.{Entry, Server}

  @type integration_id :: String.t()
  @type capability :: atom()

  @doc "Read from cache. Bypasses GenServer — direct ETS read."
  @spec get(integration_id(), capability(), atom(), map()) :: {:ok, Entry.t()} | :miss
  defdelegate get(integration_id, capability, action, args), to: Server

  @doc "Write to cache via GenServer."
  @spec put(integration_id(), capability(), atom(), map(), term(), map(), non_neg_integer()) :: :ok
  defdelegate put(integration_id, capability, action, args, data, source_attribution, ttl_ms), to: Server

  @doc "Evict all entries for {integration_id, capability} via GenServer."
  @spec invalidate(integration_id(), capability()) :: :ok
  defdelegate invalidate(integration_id, capability), to: Server

  @doc "Evict all entries for an integration across all capabilities via GenServer."
  @spec invalidate_integration(integration_id()) :: :ok
  defdelegate invalidate_integration(integration_id), to: Server

  @doc "Trigger an immediate sweep with the given hard-retention window (ms). Synchronous. Primarily for tests."
  @spec sweep(non_neg_integer()) :: :ok
  defdelegate sweep(hard_retention_ms), to: Vigil.Core.Cache.Janitor

  @doc """
  Check-or-compute with single-flight coalescing.
  On miss, `compute_fn` is called exactly once regardless of concurrent callers
  for the same key (TEST-204). On hit, `compute_fn` is never called.
  """
  @spec fetch(integration_id(), capability(), atom(), map(), non_neg_integer(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, Entry.t(), :hit | :miss} | {:error, term()}
  defdelegate fetch(integration_id, capability, action, args, ttl_ms, compute_fn), to: Server
end
