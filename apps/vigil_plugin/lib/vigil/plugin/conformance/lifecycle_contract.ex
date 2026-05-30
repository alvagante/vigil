defmodule Vigil.Plugin.Conformance.LifecycleContract do
  @moduledoc """
  Asserts a plugin implements the full `Vigil.Plugin` contract surface
  (design §3.1) and the health-check lifecycle hook (§3.6).

  This contract is the forcing function for "the behaviour is fully defined":
  it lists every required callback, so a plugin that omits one fails
  conformance rather than silently passing. When the contract grows, this list
  grows with it (ROAD-105).
  """

  alias Vigil.Plugin.Conformance.Check

  # The complete `Vigil.Plugin` callback set (design §3.1), as {name, arity}.
  @required_callbacks [
    {:plugin_id, 0},
    {:display_name, 0},
    {:contract_version, 0},
    {:capabilities, 0},
    {:config_schema, 0},
    {:child_spec, 1},
    {:defaults, 0},
    {:operational_permissions, 0}
  ]

  @spec run(map()) :: [Check.t()]
  def run(%{plugin: plugin}) do
    callback_checks(plugin) ++ return_shape_checks(plugin) ++ [health_check(plugin)]
  end

  defp callback_checks(plugin) do
    Enum.map(@required_callbacks, fn {name, arity} ->
      check_name = "lifecycle:callback:#{name}/#{arity}"

      if function_exported?(plugin, name, arity) do
        Check.pass(check_name)
      else
        Check.fail(check_name, "#{inspect(plugin)} does not export #{name}/#{arity}")
      end
    end)
  end

  defp return_shape_checks(plugin) do
    [
      shape("lifecycle:plugin_id/0:string", fn -> is_binary(plugin.plugin_id()) end),
      shape("lifecycle:contract_version/0:version", fn ->
        match?(%Version{}, plugin.contract_version())
      end),
      shape("lifecycle:config_schema/0:schema", fn ->
        match?(%Vigil.Plugin.Schema{}, plugin.config_schema())
      end),
      shape("lifecycle:defaults/0:budgets", fn ->
        d = plugin.defaults()
        is_map(d.cache_ttl) and is_map(d.timeouts) and is_integer(d.concurrency)
      end),
      shape("lifecycle:operational_permissions/0:permissions", fn ->
        perms = plugin.operational_permissions()
        is_list(perms) and Enum.all?(perms, &match?(%Vigil.Plugin.Permission{}, &1))
      end)
    ]
  end

  defp health_check(plugin) do
    name = "lifecycle:health_check/1:status"

    cond do
      not function_exported?(plugin, :health_check, 1) ->
        Check.fail(name, "#{inspect(plugin)} does not implement Vigil.Plugin.Health")

      match?({:ok, status} when status in [:healthy, :degraded, :unhealthy], plugin.health_check("conformance")) ->
        Check.pass(name)

      true ->
        Check.fail(name, "health_check/1 did not return {:ok, status}")
    end
  end

  defp shape(name, fun) do
    if fun.(), do: Check.pass(name), else: Check.fail(name, "#{name} returned an unexpected shape")
  rescue
    e -> Check.fail(name, "#{name} raised #{Exception.message(e)}")
  end
end
