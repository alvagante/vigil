defmodule Vigil.Integrations.Puppet.FakePuppetDB do
  @moduledoc """
  Test double for `Vigil.Integrations.Puppet.PuppetDB.HTTP`, backed by an
  Agent so a test can script node lists, facts, errors, and more, then observe
  how the plugin handles them.

  Agent state:

      %{
        nodes: [map()],                        # returned for nodes queries
        facts: %{certname => [fact_map()]},    # returned for facts queries
        reports: [map()],                      # returned for reports queries
        events: %{certname => [event_map()]},  # returned for events queries
        catalogs: %{certname => map()},        # returned for catalog queries
        error: term() | nil                    # when set, all queries fail
      }

  Pass the Agent pid via `config["http_opts"] = [agent: pid]`.
  """

  @behaviour Vigil.Integrations.Puppet.PuppetDB.HTTP

  def new(attrs \\ %{}) do
    state = Map.merge(%{nodes: [], facts: %{}, reports: [], events: %{}, catalogs: %{}, error: nil}, attrs)
    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  def set_nodes(agent, nodes), do: Agent.update(agent, &Map.put(&1, :nodes, nodes))

  def set_facts(agent, certname, facts),
    do:
      Agent.update(
        agent,
        &Map.update(&1, :facts, %{certname => facts}, fn f -> Map.put(f, certname, facts) end)
      )

  def set_reports(agent, reports), do: Agent.update(agent, &Map.put(&1, :reports, reports))

  def set_events(agent, certname, events),
    do:
      Agent.update(
        agent,
        &Map.update(&1, :events, %{certname => events}, fn e -> Map.put(e, certname, events) end)
      )

  def set_catalog(agent, certname, catalog),
    do:
      Agent.update(
        agent,
        &Map.update(&1, :catalogs, %{certname => catalog}, fn c -> Map.put(c, certname, catalog) end)
      )

  def set_error(agent, reason), do: Agent.update(agent, &Map.put(&1, :error, reason))
  def clear_error(agent), do: Agent.update(agent, &Map.put(&1, :error, nil))

  @impl true
  def query(_base_url, pql, opts) do
    agent = Keyword.fetch!(opts, :agent)
    state = Agent.get(agent, & &1)

    if state.error do
      {:error, state.error}
    else
      {:ok, dispatch(pql, state)}
    end
  end

  defp dispatch(pql, state) do
    cond do
      String.contains?(pql, "facts[") ->
        certname = extract_certname(pql)
        Map.get(state.facts, certname, [])

      String.contains?(pql, "reports[") ->
        state.reports

      String.contains?(pql, "events[") ->
        certname = extract_certname(pql)
        Map.get(state.events, certname, [])

      String.contains?(pql, "catalogs[") ->
        certname = extract_certname(pql)
        case Map.get(state.catalogs, certname) do
          nil -> []
          catalog -> [catalog]
        end

      true ->
        state.nodes
    end
  end

  defp extract_certname(pql) do
    case Regex.run(~r/certname = "([^"]+)"/, pql) do
      [_, certname] -> certname
      _ -> nil
    end
  end
end
