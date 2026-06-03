defmodule Vigil.Integrations.Puppet.PuppetDB.FinchHTTP do
  @moduledoc """
  Production HTTP transport for PuppetDB using Finch.

  mTLS is configured at pool level via `conn_opts` when cert/key/cacert paths
  are present in `opts`. Each integration gets its own named Finch pool so TLS
  configuration is fully isolated between instances (PUP-801, PUP-803).

  Pool name is passed as `opts[:finch_name]` by the per-integration supervisor.
  """

  @behaviour Vigil.Integrations.Puppet.PuppetDB.HTTP

  @query_path "/pdb/query/v4"

  @impl true
  def query(base_url, pql, opts) do
    finch_name = Keyword.fetch!(opts, :finch_name)
    timeout = Keyword.get(opts, :timeout, 30_000)

    body = Jason.encode!(%{query: pql})
    url = base_url <> @query_path

    request =
      Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(request, finch_name, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds the Finch child spec for a per-integration connection pool.

  `integration_id` is used to derive a stable atom pool name.
  `config` may contain mTLS paths: `"puppetdb.client_cert"`, `"puppetdb.client_key"`,
  `"puppetdb.ca_cert"`, and `"puppetdb.url"` (for pool-level host matching).
  """
  @spec child_spec(String.t(), map()) :: Supervisor.child_spec()
  def child_spec(integration_id, config) do
    name = pool_name(integration_id)
    base_url = Map.get(config, "puppetdb.url", "")
    pool_opts = build_pool_opts(config)

    {Finch,
     name: name,
     pools: %{
       base_url => pool_opts
     }}
  end

  @spec pool_name(String.t()) :: atom()
  def pool_name(integration_id), do: :"puppet_pdb_#{integration_id}"

  defp build_pool_opts(config) do
    transport_opts = build_transport_opts(config)

    if transport_opts == [] do
      [size: 4]
    else
      [size: 4, conn_opts: [transport_opts: transport_opts]]
    end
  end

  defp build_transport_opts(config) do
    []
    |> maybe_add_cert(config)
    |> maybe_add_ca(config)
    |> maybe_add_verify()
  end

  defp maybe_add_cert(opts, %{"puppetdb.client_cert" => cert, "puppetdb.client_key" => key})
       when is_binary(cert) and is_binary(key) do
    opts ++ [certfile: cert, keyfile: key]
  end

  defp maybe_add_cert(opts, _), do: opts

  defp maybe_add_ca(opts, %{"puppetdb.ca_cert" => ca}) when is_binary(ca) do
    opts ++ [cacertfile: ca]
  end

  defp maybe_add_ca(opts, _), do: opts

  defp maybe_add_verify([]), do: []
  defp maybe_add_verify(opts), do: opts ++ [verify: :verify_peer]
end
