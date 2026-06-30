defmodule Vigil.Integrations.Ansible.InventoryParser do
  @moduledoc """
  Parses the JSON output of `ansible-inventory --list` into `Vigil.Plugin.Node` structs.

  The `--list` format:
    - `_meta.hostvars`: map of hostname → host variable map (authoritative host list)
    - All other top-level keys (except `_meta`) are group names with `hosts` and `children`
    - `all` and `ungrouped` are standard groups emitted by Ansible

  Groups are captured into `node.metadata.groups` as a list of group names.
  Connection metadata (`ansible_host`, `ansible_user`, `ansible_port`) goes into
  `node.metadata.connection` without being surfaced in the primary attributes.
  """

  alias Vigil.Plugin.Node

  @doc "Parse the decoded JSON map from `ansible-inventory --list`."
  @spec parse(map(), Vigil.Plugin.integration_id()) :: {:ok, [Node.t()]} | {:error, term()}
  def parse(inventory_map, _integration_id) when is_map(inventory_map) do
    hostvars = get_in(inventory_map, ["_meta", "hostvars"]) || %{}
    group_membership = build_group_membership(inventory_map)

    nodes =
      Enum.map(hostvars, fn {hostname, vars} ->
        groups = Map.get(group_membership, hostname, [])
        build_node(hostname, vars, groups)
      end)

    {:ok, nodes}
  end

  def parse(_, _), do: {:error, :invalid_inventory}

  defp build_node(hostname, vars, groups) do
    primary_ip = vars["ansible_host"]

    %Node{
      name: hostname,
      display_name: hostname,
      attributes: %{
        "hostname" => hostname,
        "primary_ip" => primary_ip,
        "groups" => groups,
        "connection" => %{
          "host" => primary_ip || hostname,
          "user" => vars["ansible_user"],
          "port" => vars["ansible_port"],
          "become" => vars["ansible_become"],
          "become_user" => vars["ansible_become_user"]
        }
      },
      targetable?: true
    }
  end

  defp build_group_membership(inventory_map) do
    inventory_map
    |> Map.drop(["_meta"])
    |> Enum.reduce(%{}, fn {group_name, group_data}, acc ->
      hosts = group_data["hosts"] || []
      Enum.reduce(hosts, acc, fn host, inner_acc ->
        Map.update(inner_acc, host, [group_name], &[group_name | &1])
      end)
    end)
  end
end
