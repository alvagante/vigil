defmodule Vigil.Integrations.Bolt.FakeCLI do
  @moduledoc """
  Test double for `Vigil.Integrations.Bolt.CLI`, backed by a caller-owned
  Agent so tests can script inventory, command, task, and plan responses
  without a real `bolt` binary.

  Agent state:

      %{
        inventory: map() | nil,       # bolt inventory show
        command_result: map() | nil,  # bolt command run
        task_list: map() | nil,       # bolt task show (list)
        task_detail: map() | nil,     # bolt task show <name> (detail)
        task_run_result: map() | nil, # bolt task run
        plan_list: map() | nil,       # bolt plan show (list)
        plan_detail: map() | nil,     # bolt plan show <name> (detail)
        plan_run_result: map() | nil, # bolt plan run
        error: term() | nil,
        last_args: [String.t()] | nil
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
          task_list: %{"tasks" => [], "modulepath" => []},
          task_detail: %{},
          task_run_result: %{"items" => []},
          plan_list: %{"plans" => [], "modulepath" => []},
          plan_detail: %{},
          plan_run_result: %{},
          error: nil,
          last_args: nil
        },
        attrs
      )

    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  def set_inventory(agent, inventory_map),
    do: Agent.update(agent, &Map.put(&1, :inventory, inventory_map))

  def set_command_result(agent, result_map),
    do: Agent.update(agent, &Map.put(&1, :command_result, result_map))

  def set_task_list(agent, list_map),
    do: Agent.update(agent, &Map.put(&1, :task_list, list_map))

  def set_task_detail(agent, detail_map),
    do: Agent.update(agent, &Map.put(&1, :task_detail, detail_map))

  def set_task_run_result(agent, result_map),
    do: Agent.update(agent, &Map.put(&1, :task_run_result, result_map))

  def set_plan_list(agent, list_map),
    do: Agent.update(agent, &Map.put(&1, :plan_list, list_map))

  def set_plan_detail(agent, detail_map),
    do: Agent.update(agent, &Map.put(&1, :plan_detail, detail_map))

  def set_plan_run_result(agent, result_map),
    do: Agent.update(agent, &Map.put(&1, :plan_run_result, result_map))

  def set_error(agent, reason),
    do: Agent.update(agent, &Map.put(&1, :error, reason))

  def clear_error(agent),
    do: Agent.update(agent, &Map.put(&1, :error, nil))

  def last_args(agent), do: Agent.get(agent, & &1.last_args)

  @impl Vigil.Integrations.Bolt.CLI
  def run(_executable, args, opts) do
    agent = Keyword.fetch!(opts, :agent)
    Agent.update(agent, &Map.put(&1, :last_args, args))
    state = Agent.get(agent, & &1)

    case state.error do
      nil ->
        result = dispatch(args, state)
        {:ok, %{exit_status: 0, stdout: Jason.encode!(result), stderr: ""}}

      reason ->
        {:error, reason}
    end
  end

  # Dispatch on arg prefix. For show commands, a task/plan name precedes any
  # flags; a detail call has a non-flag as the third arg.
  defp dispatch(["inventory" | _], state), do: state.inventory

  defp dispatch(["task", "show", third | _], state) when not is_nil(third) do
    if String.starts_with?(third, "-"), do: state.task_list, else: state.task_detail
  end

  defp dispatch(["task", "show"], state), do: state.task_list
  defp dispatch(["task", "run" | _], state), do: state.task_run_result

  defp dispatch(["plan", "show", third | _], state) when not is_nil(third) do
    if String.starts_with?(third, "-"), do: state.plan_list, else: state.plan_detail
  end

  defp dispatch(["plan", "show"], state), do: state.plan_list
  defp dispatch(["plan", "run" | _], state), do: state.plan_run_result
  defp dispatch(_, state), do: state.command_result
end
