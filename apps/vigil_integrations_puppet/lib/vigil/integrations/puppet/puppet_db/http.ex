defmodule Vigil.Integrations.Puppet.PuppetDB.HTTP do
  @moduledoc """
  Transport behaviour for PuppetDB HTTP calls.

  The real implementation (`FinchHTTP`) makes HTTP requests via Finch with
  optional mTLS. Tests inject `FakePuppetDB` via the integration config's
  `"http_module"` key.
  """

  @doc """
  Execute a PQL query against PuppetDB.

  `base_url` is the full PuppetDB base URL (e.g. `"https://pdb:8081"`).
  `pql` is the PQL query string (pre-escaped via `Vigil.Integrations.Puppet.PQL`).
  `opts` carries transport-specific options (Finch name, TLS params, agent pid, etc.)

  Returns `{:ok, [map()]}` on success or `{:error, reason}` on failure.
  """
  @callback query(base_url :: String.t(), pql :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
end
