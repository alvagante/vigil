defmodule Vigil.Plugin.Workers.CacheWarmer do
  @moduledoc """
  Oban worker that pre-populates the shared integration cache for one
  {integration_id, capability} pair (design §5.10.2, CACHE-009).

  Enqueued by `Vigil.Plugin.Cache.Warmer` at boot and on first-healthy events.
  Runs in the `:maintenance` queue (max 5 concurrent) so warm jobs never exhaust
  the budget that real user requests need.

  Deferred: max_concurrency_share, coalescer-skip, telemetry source tagging.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Vigil.Plugin.Dispatcher

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => int_id, "capability" => cap}}) do
    case Dispatcher.warm(int_id, String.to_existing_atom(cap)) do
      {:ok, _result} -> :ok
      {:error, _} = err -> err
    end
  end
end
