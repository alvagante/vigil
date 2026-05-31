defmodule Vigil.Integrations.SSH.FakeTransport do
  @moduledoc """
  Test double for `Vigil.Integrations.SSH.Transport`, backed by a caller-owned
  Agent so a test can script connection failures, exec responses, and observe
  how many times the pool (re)connected.

  The Agent state:

      %{
        connect_count: non_neg_integer(),     # bumped on every connect/2
        connect_error: term() | nil,          # when set, connect/2 fails with it
        fail_exec_once: boolean(),             # when true, the next exec/3 returns {:error, :closed}
        responses: %{command => {status, stdout, stderr}}
      }

  Pass the Agent pid through `transport_opts: [agent: pid]`.
  """

  @behaviour Vigil.Integrations.SSH.Transport

  def new(attrs \\ %{}) do
    state =
      Map.merge(
        %{connect_count: 0, connect_error: nil, fail_exec_once: false, responses: %{}},
        attrs
      )

    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  def connect_count(agent), do: Agent.get(agent, & &1.connect_count)

  @impl true
  def connect(host, opts) do
    agent = Keyword.fetch!(opts, :agent)

    Agent.get_and_update(agent, fn s ->
      s = %{s | connect_count: s.connect_count + 1}

      case s.connect_error do
        nil -> {{:ok, {:fake_conn, agent, host}}, s}
        err -> {{:error, err}, s}
      end
    end)
  end

  @impl true
  def exec({:fake_conn, agent, _host}, command, _timeout) do
    Agent.get_and_update(agent, fn s ->
      if s.fail_exec_once do
        {{:error, :closed}, %{s | fail_exec_once: false}}
      else
        {status, out, err} = Map.get(s.responses, command, {0, "", ""})
        {{:ok, %{exit_status: status, stdout: out, stderr: err}}, s}
      end
    end)
  end

  @impl true
  def close(_conn), do: :ok
end
