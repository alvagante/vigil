defmodule Vigil.Integrations.Ansible.FakeCLI do
  @moduledoc """
  Test double for `Vigil.Integrations.Ansible.CLI`, backed by a caller-owned
  Agent so tests can script inventory, facts, command, and playbook responses
  without a real Ansible installation.

  Agent state:
      %{
        inventory: map(),          # ansible-inventory --list JSON (decoded)
        facts: map(),              # ansible -m setup JSON (decoded)
        command_result: map(),     # ansible -m <mod> result JSON (decoded)
        playbook_result: map(),    # ansible-playbook result JSON (decoded)
        version: String.t(),       # ansible --version output
        error: term() | nil,
        last_args: [String.t()] | nil
      }

  Wire via:
      config["cli_module"] = FakeCLI
      config["cli_opts"] = [agent: agent_pid]
  """

  @behaviour Vigil.Integrations.Ansible.CLI

  @default_inventory %{
    "_meta" => %{"hostvars" => %{}},
    "all" => %{"children" => ["ungrouped"]},
    "ungrouped" => %{"hosts" => []}
  }

  @default_facts %{
    "localhost" => %{
      "ansible_facts" => %{
        "ansible_distribution" => "Ubuntu",
        "ansible_distribution_version" => "22.04",
        "ansible_kernel" => "5.15.0",
        "ansible_hostname" => "localhost",
        "ansible_fqdn" => "localhost",
        "ansible_all_ipv4_addresses" => ["127.0.0.1"],
        "ansible_processor_vcpus" => 2,
        "ansible_memtotal_mb" => 4096
      },
      "changed" => false
    }
  }

  def new(attrs \\ %{}) do
    state =
      Map.merge(
        %{
          inventory: @default_inventory,
          facts: @default_facts,
          command_result: %{"localhost" => %{"stdout" => "ok", "exit_code" => 0}},
          playbook_result: %{"play_recap" => %{}},
          version: "ansible [core 2.16.0]\n",
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

  def set_facts(agent, facts_map),
    do: Agent.update(agent, &Map.put(&1, :facts, facts_map))

  def set_command_result(agent, result_map),
    do: Agent.update(agent, &Map.put(&1, :command_result, result_map))

  def set_playbook_result(agent, result_map),
    do: Agent.update(agent, &Map.put(&1, :playbook_result, result_map))

  def set_version(agent, version_string),
    do: Agent.update(agent, &Map.put(&1, :version, version_string))

  def set_error(agent, reason), do: Agent.update(agent, &Map.put(&1, :error, reason))
  def clear_error(agent), do: Agent.update(agent, &Map.put(&1, :error, nil))

  def last_args(agent), do: Agent.get(agent, & &1.last_args)

  @impl Vigil.Integrations.Ansible.CLI
  def run(executable, args, opts) do
    agent = Keyword.fetch!(opts, :agent)
    Agent.update(agent, &Map.put(&1, :last_args, args))
    state = Agent.get(agent, & &1)

    case state.error do
      nil ->
        result = dispatch(executable, args, state)
        {:ok, %{exit_status: 0, stdout: Jason.encode!(result)}}

      reason ->
        {:error, reason}
    end
  end

  defp dispatch(executable, args, state) do
    cond do
      String.ends_with?(executable, "ansible-inventory") or "--list" in args ->
        state.inventory

      String.ends_with?(executable, "ansible-playbook") or "ansible-playbook" == Path.basename(executable) ->
        state.playbook_result

      "--version" in args ->
        state.version

      "-m" in args and "setup" == Enum.at(args, Enum.find_index(args, &(&1 == "-m")) + 1) ->
        state.facts

      true ->
        state.command_result
    end
  end
end
