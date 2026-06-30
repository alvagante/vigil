defmodule Vigil.Integrations.Puppet.Puppetserver.HTTP do
  @moduledoc """
  Transport behaviour for Puppetserver HTTP calls (environments, cache flush, code deploy).

  The real implementation (`FinchHTTP`) makes HTTP requests via Finch with
  optional mTLS. Tests inject `FakePuppetserver` via `"puppetserver.http_module"`.
  """

  @doc """
  Make an HTTP request to a Puppetserver-family endpoint.

  Returns `{:ok, decoded_body}` on success (2xx) or `{:error, reason}` on failure.
  `decoded_body` is a map/list for JSON responses, or `:ok` for empty 204 responses.
  """
  @callback request(
              method :: :get | :delete | :post,
              url :: String.t(),
              body :: map() | nil,
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}
end
