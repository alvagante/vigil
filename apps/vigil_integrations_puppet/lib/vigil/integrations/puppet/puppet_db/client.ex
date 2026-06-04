defmodule Vigil.Integrations.Puppet.PuppetDB.Client do
  @moduledoc """
  Functional interface for PuppetDB queries.

  Routes all HTTP calls through the configured transport module (production:
  `FinchHTTP`; tests: `FakePuppetDB`). Config is read from `ConfigServer` on
  every call so hot reloads take effect immediately. Circuit breaker state is
  checked before making any upstream call and updated based on outcome.
  """

  alias Vigil.Integrations.Puppet.{CircuitBreaker, ConfigServer}
  alias Vigil.Integrations.Puppet.PuppetDB.FinchHTTP
  alias Vigil.Plugin.Error

  @doc "Query PuppetDB with the given PQL string."
  @spec query(Vigil.Plugin.integration_id(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def query(integration_id, pql, opts \\ []) do
    with {:ok, config} <- ConfigServer.get_config(integration_id),
         :ok <- CircuitBreaker.check(integration_id),
         http_module <- http_module(config),
         base_url <- Map.fetch!(config, "puppetdb.url"),
         http_opts <- build_http_opts(integration_id, config, opts) do
      result = http_module.query(base_url, pql, http_opts)
      update_circuit_breaker(integration_id, result)
      result
    else
      {:error, :not_found} ->
        {:error,
         %Error{
           category: :configuration,
           message: "no running Puppet integration for #{inspect(integration_id)}",
           retriable?: false
         }}

      {:error, :open} ->
        {:error,
         %Error{
           category: :transient_external,
           message:
             "circuit breaker open for #{inspect(integration_id)} — PuppetDB is unavailable",
           retriable?: true
         }}
    end
  end

  defp http_module(config), do: Map.get(config, "http_module", FinchHTTP)

  defp build_http_opts(integration_id, config, call_opts) do
    base =
      case http_module(config) do
        FinchHTTP -> [finch_name: FinchHTTP.pool_name(integration_id)]
        _ -> Map.get(config, "http_opts", [])
      end

    base ++ call_opts
  end

  defp update_circuit_breaker(integration_id, {:ok, _}),
    do: CircuitBreaker.record_success(integration_id)

  defp update_circuit_breaker(integration_id, {:error, _}),
    do: CircuitBreaker.record_failure(integration_id)
end
