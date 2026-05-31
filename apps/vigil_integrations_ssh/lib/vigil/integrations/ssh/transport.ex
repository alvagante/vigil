defmodule Vigil.Integrations.SSH.Transport do
  @moduledoc """
  The seam between the SSH plugin and an actual SSH client.

  Abstracting the transport keeps `ConnectionPool`, fact gathering, and health
  probing testable without a live `sshd`: tests inject a fake implementation,
  production uses `Vigil.Integrations.SSH.Transport.ErlangSSH` (OTP's `:ssh`).
  The implementation is selected per integration via the `"transport"` config
  key, defaulting to the Erlang transport.

  A `conn` is an opaque term owned by the implementation; callers only pass it
  back to `exec/3` and `close/1`.
  """

  @type conn :: term()
  @type host :: String.t()
  @type exec_result :: %{exit_status: integer(), stdout: binary(), stderr: binary()}

  @callback connect(host(), opts :: keyword()) :: {:ok, conn()} | {:error, term()}
  @callback exec(conn(), command :: String.t(), timeout :: timeout()) ::
              {:ok, exec_result()} | {:error, term()}
  @callback close(conn()) :: :ok

  @default_transport Vigil.Integrations.SSH.Transport.ErlangSSH

  @doc """
  Resolve the transport module and its opts from an integration config map.
  Production configs omit `"transport"`, yielding the Erlang transport.
  """
  @spec from_config(map()) :: {module(), keyword()}
  def from_config(config) do
    module = Map.get(config, "transport", @default_transport)
    opts = Map.get(config, "transport_opts", [])
    {module, opts}
  end
end
