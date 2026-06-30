defmodule Vigil.Integrations.Puppet.Puppetserver.FinchHTTP do
  @moduledoc """
  Production HTTP transport for Puppetserver using Finch.

  Handles GET (environment list), DELETE (cache flush), and POST (code deploy
  webhook / Code Manager API). mTLS configuration mirrors the PuppetDB Finch
  pool; each integration gets its own named pool.
  """

  @behaviour Vigil.Integrations.Puppet.Puppetserver.HTTP

  @impl true
  def request(method, url, body, opts) do
    finch_name = Keyword.fetch!(opts, :finch_name)
    timeout = Keyword.get(opts, :timeout, 30_000)
    bearer_token = Keyword.get(opts, :bearer_token)

    headers =
      [{"content-type", "application/json"}]
      |> maybe_add_bearer(bearer_token)

    encoded_body = if body, do: Jason.encode!(body), else: nil

    request = Finch.build(method, url, headers, encoded_body)

    case Finch.request(request, finch_name, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        if resp_body == "" or resp_body == nil,
          do: {:ok, :ok},
          else: Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Builds the Finch child spec for the per-integration Puppetserver pool."
  @spec child_spec(String.t(), map()) :: Supervisor.child_spec()
  def child_spec(integration_id, config) do
    name = pool_name(integration_id)
    base_url = Map.get(config, "puppetserver.url", "")
    pool_opts = build_pool_opts(config)

    {Finch,
     name: name,
     pools: %{
       base_url => pool_opts
     }}
  end

  @spec pool_name(String.t()) :: atom()
  def pool_name(integration_id), do: :"puppet_pss_#{integration_id}"

  defp build_pool_opts(config) do
    transport_opts = build_transport_opts(config)
    if transport_opts == [], do: [size: 2], else: [size: 2, conn_opts: [transport_opts: transport_opts]]
  end

  defp build_transport_opts(config) do
    []
    |> maybe_add_cert(config)
    |> maybe_add_ca(config)
    |> maybe_add_verify()
  end

  defp maybe_add_cert(opts, %{"puppetserver.client_cert" => cert, "puppetserver.client_key" => key})
       when is_binary(cert) and is_binary(key),
       do: opts ++ [certfile: cert, keyfile: key]

  defp maybe_add_cert(opts, _), do: opts

  defp maybe_add_ca(opts, %{"puppetserver.ca_cert" => ca}) when is_binary(ca),
    do: opts ++ [cacertfile: ca]

  defp maybe_add_ca(opts, _), do: opts

  defp maybe_add_verify([]), do: []
  defp maybe_add_verify(opts), do: opts ++ [verify: :verify_peer]

  defp maybe_add_bearer(headers, nil), do: headers
  defp maybe_add_bearer(headers, token), do: [{"authorization", "Bearer #{token}"} | headers]
end
