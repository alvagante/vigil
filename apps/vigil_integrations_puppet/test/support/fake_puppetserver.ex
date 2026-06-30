defmodule Vigil.Integrations.Puppet.FakePuppetserver do
  @moduledoc """
  Test double for `Vigil.Integrations.Puppet.Puppetserver.HTTP`.

  An Agent-backed fake that routes responses by URL pattern. Wire it via:

      config["puppetserver.http_module"] = FakePuppetserver
      config["puppetserver.http_opts"] = [agent: agent_pid]

  Agent state:

      %{
        environments: ["production", "staging"],   # returned for /puppet/v3/environments
        deploy_result: {:ok, %{}} | {:error, reason}, # returned for deploy POST calls
        error: term() | nil                         # when set, all requests fail
      }
  """

  @behaviour Vigil.Integrations.Puppet.Puppetserver.HTTP

  def new(attrs \\ %{}) do
    state = Map.merge(%{environments: [], deploy_result: {:ok, %{}}, error: nil}, attrs)
    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  def set_environments(agent, names),
    do: Agent.update(agent, &Map.put(&1, :environments, names))

  def set_deploy_result(agent, result),
    do: Agent.update(agent, &Map.put(&1, :deploy_result, result))

  def set_error(agent, reason), do: Agent.update(agent, &Map.put(&1, :error, reason))
  def clear_error(agent), do: Agent.update(agent, &Map.put(&1, :error, nil))

  @impl true
  def request(_method, url, _body, opts) do
    agent = Keyword.fetch!(opts, :agent)
    state = Agent.get(agent, & &1)

    if state.error do
      {:error, state.error}
    else
      dispatch(url, state)
    end
  end

  defp dispatch(url, state) do
    cond do
      String.contains?(url, "/puppet/v3/environments") ->
        envs = Map.new(state.environments, &{&1, %{"settings" => %{}}})
        {:ok, %{"environments" => envs}}

      String.contains?(url, "/puppet-admin-api/v1/environment-cache") ->
        {:ok, :flushed}

      true ->
        state.deploy_result
    end
  end
end
