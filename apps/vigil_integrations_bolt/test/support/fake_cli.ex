defmodule Vigil.Integrations.Bolt.FakeCLI do
  @moduledoc """
  Test double for `Vigil.Integrations.Bolt.CLI`, backed by a caller-owned
  Agent so tests can script inventory and command responses without a real
  `bolt` binary.

  Agent state:

      %{
        inventory: map() | nil,       # parsed as JSON for inventory show calls
        command_result: map() | nil,  # parsed as JSON for command run calls
        error: term() | nil,          # when set, all calls fail with this
        last_args: [String.t()] | nil # last args received
      }

  Pass the Agent pid via `opts[:agent]` in the plugin config's `"cli_opts"`.
  """

  @behaviour Vigil.Integrations.Bolt.CLI

  def new(attrs \\ %{}) do
    state =
      Map.merge(
        %{
          inventory: %{"targets" => []},
          command_result: %{"items" => []},
          error: nil,
          last_args: nil
        },
        attrs
      )

    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  def set_inventory(agent, inventory_map) do
    Agent.update(agent, &Map.put(&1, :inventory, inventory_map))
  end

  def set_command_result(agent, result_map) do
    Agent.update(agent, &Map.put(&1, :command_result, result_map))
  end

  def set_error(agent, reason) do
    Agent.update(agent, &Map.put(&1, :error, reason))
  end

  def clear_error(agent) do
    Agent.update(agent, &Map.put(&1, :error, nil))
  end

  def last_args(agent), do: Agent.get(agent, & &1.last_args)

  @impl Vigil.Integrations.Bolt.CLI
  def run(_executable, args, opts) do
    agent = Keyword.fetch!(opts, :agent)
    Agent.update(agent, &Map.put(&1, :last_args, args))
    state = Agent.get(agent, & &1)

    case state.error do
      nil ->
        result =
          if List.starts_with?(args, ["inventory"]) do
            Jason.encode!(state.inventory)
          else
            Jason.encode!(state.command_result)
          end

        {:ok, %{exit_status: 0, stdout: result, stderr: ""}}

      reason ->
        {:error, reason}
    end
  end
end
