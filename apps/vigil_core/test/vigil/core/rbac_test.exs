defmodule Vigil.Core.RBACTest do
  use Vigil.DataCase, async: false
  use ExUnitProperties

  alias Vigil.Core.{Accounts, RBAC}

  defp make_user(username) do
    {:ok, user} = Accounts.register_user(%{username: username, password: "rbac_test_password!"})
    user
  end

  defp make_role(name) do
    {:ok, role} = RBAC.create_role(%{name: name})
    role
  end

  defp grant(role, action) do
    {:ok, _} = RBAC.grant_permission(role, %{action: action})
  end

  defp assign(user, role) do
    :ok = RBAC.assign_role(user, role, source: "direct")
  end

  defp context(opts \\ []) do
    %RBAC.Context{
      integration_id: opts[:integration_id],
      resolved_targets: opts[:resolved_targets] || [],
      artifact: opts[:artifact]
    }
  end

  describe "check/3" do
    test "returns :ok when user's role has the matching permission" do
      user = make_user("rbac_allow_user")
      role = make_role("rbac_allow_role")
      grant(role, "ssh:command:execute")
      assign(user, role)

      assert :ok = RBAC.check(user, "ssh:command:execute", context())
    end

    test "returns {:error, :denied} when no role has the permission" do
      user = make_user("rbac_deny_user")
      role = make_role("rbac_deny_role")
      grant(role, "puppet:inventory:read")
      assign(user, role)

      assert {:error, :denied} = RBAC.check(user, "ssh:command:execute", context())
    end

    test "returns {:error, :denied} for a user with no role assignments" do
      user = make_user("rbac_norole_user")
      assert {:error, :denied} = RBAC.check(user, "ssh:command:execute", context())
    end

    test "wildcard action \"*\" grants access to any requested action" do
      user = make_user("rbac_wildcard_user")
      role = make_role("rbac_wildcard_role")
      grant(role, "*")
      assign(user, role)

      assert :ok = RBAC.check(user, "ssh:command:execute", context())
      assert :ok = RBAC.check(user, "puppet:inventory:read", context())
      assert :ok = RBAC.check(user, "rbac:role:update", context())
    end

    test "returns :ok from union of multiple roles" do
      user = make_user("rbac_multi_user")
      role_a = make_role("rbac_multi_role_a")
      role_b = make_role("rbac_multi_role_b")
      grant(role_a, "puppet:inventory:read")
      grant(role_b, "ssh:command:execute")
      assign(user, role_a)
      assign(user, role_b)

      assert :ok = RBAC.check(user, "ssh:command:execute", context())
      assert :ok = RBAC.check(user, "puppet:inventory:read", context())
    end
  end

  describe "property: union semantics" do
    property "check result is the same regardless of role assignment order" do
      check all names <- uniq_list_of(string(:alphanumeric, min_length: 4), min_length: 1, max_length: 4),
                action <- member_of(["ssh:command:execute", "puppet:inventory:read", "bolt:task:run"]),
                target_action <- member_of(["ssh:command:execute", "puppet:inventory:read", "bolt:task:run"]) do

        user_a = make_user("prop_a_#{:erlang.unique_integer([:positive])}")
        user_b = make_user("prop_b_#{:erlang.unique_integer([:positive])}")

        roles =
          Enum.map(names, fn n ->
            role = make_role("prop_role_#{n}_#{:erlang.unique_integer([:positive])}")
            grant(role, action)
            role
          end)

        # Assign in order to user_a, reverse order to user_b
        Enum.each(roles, &assign(user_a, &1))
        Enum.each(Enum.reverse(roles), &assign(user_b, &1))

        result_a = RBAC.check(user_a, target_action, context())
        result_b = RBAC.check(user_b, target_action, context())

        assert result_a == result_b
      end
    end
  end

  describe "TEST-202a: constant query count regardless of target count" do
    setup do
      user = make_user("query_count_user")
      role = make_role("query_count_role")
      grant(role, "ssh:command:execute")
      assign(user, role)
      %{user: user}
    end

    # Spec: RBAC check against N targets issues a constant number of queries at N=1,10,100,1000
    test "check issues exactly 2 DB queries regardless of target count N=1,10,100,1000",
         %{user: user} do
      counts =
        for n <- [1, 10, 100, 1000] do
          targets = Enum.map(1..n, fn i -> %{id: "node-#{i}", tags: %{}} end)
          ctx = context(resolved_targets: targets)
          count_queries(fn -> RBAC.check(user, "ssh:command:execute", ctx) end)
        end

      [first | _] = counts
      assert first > 0, "telemetry reported 0 queries — check the event name [:vigil, :repo, :query]"
      # 2 queries: one for user_roles, one for role_permissions — regardless of N
      assert counts == [2, 2, 2, 2],
             "Expected [2,2,2,2] (constant), got #{inspect(counts)}"
    end
  end

  describe "PermissionCache" do
    test "for_principal/1 returns permissions for a known user" do
      user = make_user("cache_user")
      role = make_role("cache_role")
      grant(role, "ssh:command:execute")
      assign(user, role)

      perms = RBAC.PermissionCache.for_principal(user.id)
      assert is_list(perms)
      assert Enum.any?(perms, &(&1.action == "ssh:command:execute"))
    end

    test "invalidate/1 causes the cache to be rebuilt on next access" do
      user = make_user("cache_inv_user")
      role = make_role("cache_inv_role")
      grant(role, "ssh:command:execute")
      assign(user, role)

      _first = RBAC.PermissionCache.for_principal(user.id)

      # Add another permission
      role2 = make_role("cache_inv_role2")
      grant(role2, "puppet:inventory:read")
      assign(user, role2)

      # Without invalidation the old cache might be returned
      RBAC.PermissionCache.invalidate(user.id)

      perms = RBAC.PermissionCache.for_principal(user.id)
      assert Enum.any?(perms, &(&1.action == "puppet:inventory:read"))
    end
  end

  # Helper: count DB queries executed by fun
  defp count_queries(fun) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "query-counter-#{inspect(ref)}",
      [:vigil, :repo, :query],
      fn _event, _measures, _meta, _config ->
        send(test_pid, {:query, ref})
      end,
      nil
    )

    fun.()

    :telemetry.detach("query-counter-#{inspect(ref)}")

    receive_count(ref, 0)
  end

  defp receive_count(ref, acc) do
    receive do
      {:query, ^ref} -> receive_count(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
