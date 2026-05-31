defmodule Vigil.Integrations.SSH.Transport.ErlangSSH do
  @moduledoc """
  Production `Vigil.Integrations.SSH.Transport` backed by OTP's `:ssh` client.

  Host-key verification is **not** disabled by default (`SSH-402`, `SSH-404`):
  the client honours the host system's `known_hosts` via `user_dir`. A
  `skip_host_key_check` opt is available for development and turns on
  `silently_accept_hosts` with a logged warning.

  This module talks to a real `sshd` and is therefore exercised by integration
  testing against a live host rather than the DB-free unit suite; the unit tests
  drive the pool and plugin through a fake transport instead.
  """

  @behaviour Vigil.Integrations.SSH.Transport

  require Logger

  @impl true
  def connect(host, opts) do
    port = Keyword.get(opts, :port) || 22
    timeout = Keyword.get(opts, :connect_timeout_ms, 10_000)

    case :ssh.connect(String.to_charlist(host), port, ssh_options(opts), timeout) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exec(conn, command, timeout) do
    with {:ok, channel} <- :ssh_connection.session_channel(conn, timeout),
         :success <- :ssh_connection.exec(conn, channel, String.to_charlist(command), timeout) do
      collect(conn, channel, timeout, %{exit_status: nil, stdout: "", stderr: ""})
    else
      :failure -> {:error, :exec_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(conn), do: :ssh.close(conn)

  defp ssh_options(opts) do
    base = [
      # Auth is non-interactive; never block on a TTY prompt.
      user_interaction: false,
      auth_methods: ~c"publickey,keyboard-interactive,password"
    ]

    base
    |> maybe_put(:user, opts[:user] && String.to_charlist(opts[:user]))
    |> maybe_put(:user_dir, opts[:user_dir] && String.to_charlist(opts[:user_dir]))
    |> host_key_check(opts[:skip_host_key_check])
  end

  defp host_key_check(opts, true) do
    Logger.warning("[ssh] skip_host_key_check enabled — host identity is NOT verified")
    Keyword.put(opts, :silently_accept_hosts, true)
  end

  defp host_key_check(opts, _), do: opts

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Accumulate channel data until the channel closes, then return the transcript.
  defp collect(conn, channel, timeout, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        collect(conn, channel, timeout, %{acc | stdout: acc.stdout <> data})

      {:ssh_cm, ^conn, {:data, ^channel, 1, data}} ->
        collect(conn, channel, timeout, %{acc | stderr: acc.stderr <> data})

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect(conn, channel, timeout, %{acc | exit_status: status})

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect(conn, channel, timeout, acc)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        {:ok, %{acc | exit_status: acc.exit_status || 0}}
    after
      timeout -> {:error, :timeout}
    end
  end
end
