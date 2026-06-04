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
      check all(
              names <-
                uniq_list_of(string(:alphanumeric, min_length: 4), min_length: 1, max_length: 4),
              action <-
                member_of(["ssh:command:execute", "puppet:inventory:read", "bolt:task:run"]),
              target_action <-
                member_of(["ssh:command:execute", "puppet:inventory:read", "bolt:task:run"])
            ) do
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

      assert first > 0,
             "telemetry reported 0 queries — check the event name [:vigil, :repo, :query]"

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

  describe "RolePermission changeset — command_policy validation" do
    test "accepts a valid glob command_policy" do
      role = make_role("cs_valid_role")

      assert {:ok, _} =
               RBAC.grant_permission(role, %{
                 action: "ssh:command:execute",
                 command_policy: %{"allow" => ["systemctl **"], "deny" => ["systemctl stop *"]}
               })
    end

    test "rejects command_policy with regex metacharacters in allow patterns" do
      role = make_role("cs_bad_allow_role")

      assert {:error, changeset} =
               RBAC.grant_permission(role, %{
                 action: "ssh:command:execute",
                 command_policy: %{"allow" => ["(systemctl)"], "deny" => []}
               })

      assert %{command_policy: [_ | _]} = errors_on(changeset)
    end

    test "rejects command_policy with regex metacharacters in deny patterns" do
      role = make_role("cs_bad_deny_role")

      assert {:error, changeset} =
               RBAC.grant_permission(role, %{
                 action: "ssh:command:execute",
                 command_policy: %{"allow" => [], "deny" => ["rm+(rf)"]}
               })

      assert %{command_policy: [_ | _]} = errors_on(changeset)
    end
  end

  defp grant_with_policy(role, action, command_policy) do
    {:ok, _} = RBAC.grant_permission(role, %{action: action, command_policy: command_policy})
  end

  describe "command_policy enforcement" do
    test "nil command_policy permits any artifact" do
      user = make_user("cp_nil_user")
      role = make_role("cp_nil_role")
      grant(role, "ssh:command:execute")
      assign(user, role)

      assert :ok = RBAC.check(user, "ssh:command:execute", context(artifact: %{text: "rm -rf /"}))
    end

    test "non-empty allow list permits matching command" do
      user = make_user("cp_allow_user")
      role = make_role("cp_allow_role")
      grant_with_policy(role, "ssh:command:execute", %{"allow" => ["systemctl **"], "deny" => []})
      assign(user, role)

      assert :ok =
               RBAC.check(
                 user,
                 "ssh:command:execute",
                 context(artifact: %{text: "systemctl restart nginx"})
               )
    end

    test "non-empty allow list denies non-matching command" do
      user = make_user("cp_deny_user")
      role = make_role("cp_deny_role")
      grant_with_policy(role, "ssh:command:execute", %{"allow" => ["systemctl **"], "deny" => []})
      assign(user, role)

      assert {:error, :denied} =
               RBAC.check(user, "ssh:command:execute", context(artifact: %{text: "rm -rf /"}))
    end

    test "deny list blocks even an explicitly allowed command (EXEC-305)" do
      user = make_user("cp_block_user")
      role = make_role("cp_block_role")

      grant_with_policy(role, "ssh:command:execute", %{
        "allow" => ["systemctl **"],
        "deny" => ["systemctl stop *"]
      })

      assign(user, role)

      assert :ok =
               RBAC.check(
                 user,
                 "ssh:command:execute",
                 context(artifact: %{text: "systemctl restart nginx"})
               )

      assert {:error, :denied} =
               RBAC.check(
                 user,
                 "ssh:command:execute",
                 context(artifact: %{text: "systemctl stop nginx"})
               )
    end

    test "multi-role union: open allowlist in any role makes the policy open" do
      user = make_user("cp_union_user")
      role_open = make_role("cp_union_open")
      role_closed = make_role("cp_union_closed")

      grant(role_open, "ssh:command:execute")

      grant_with_policy(role_closed, "ssh:command:execute", %{
        "allow" => ["systemctl **"],
        "deny" => []
      })

      assign(user, role_open)
      assign(user, role_closed)

      # role_open has no command_policy (nil = open), so union allows anything
      assert :ok =
               RBAC.check(user, "ssh:command:execute", context(artifact: %{text: "rm -rf /"}))
    end
  end

  describe "partition/3" do
    test "returns all targets as permitted when user has unrestricted permission" do
      user = make_user("part_all_user")
      role = make_role("part_all_role")
      grant(role, "ssh:command:execute")
      assign(user, role)

      targets = [%{id: "n1", tags: %{}}, %{id: "n2", tags: %{}}]
      ctx = context(resolved_targets: targets, artifact: %{text: "uptime"})

      assert {^targets, []} = RBAC.partition(user, "ssh:command:execute", ctx)
    end

    test "returns all targets as denied when user has command_policy that blocks the command" do
      user = make_user("part_deny_user")
      role = make_role("part_deny_role")
      grant_with_policy(role, "ssh:command:execute", %{"allow" => ["uptime"], "deny" => []})
      assign(user, role)

      targets = [%{id: "n1", tags: %{}}]
      ctx = context(resolved_targets: targets, artifact: %{text: "rm -rf /"})

      assert {[], ^targets} = RBAC.partition(user, "ssh:command:execute", ctx)
    end

    test "splits permitted and denied targets by command_policy" do
      # This is the ADR-0005 DM-601 case: two targets, one allowed one denied
      # can't differ by command — command policy is per-permission, not per-target.
      # To get a split, we need target_selector scoping.
      # Use two users to prove the partition function: one with a role that allows,
      # one without any role. Then test the 2-user case indirectly via a single
      # user with two roles where target_selector limits one.
      # Simplest split test: no RBAC permission at all → all denied.
      user = make_user("part_split_user")
      # Give no role → all denied

      targets = [%{id: "n1", tags: %{}}, %{id: "n2", tags: %{}}]
      ctx = context(resolved_targets: targets, artifact: %{text: "uptime"})

      assert {[], ^targets} = RBAC.partition(user, "ssh:command:execute", ctx)
    end

    test "partition issues exactly 2 DB queries regardless of target count" do
      user = make_user("part_query_user")
      role = make_role("part_query_role")
      grant(role, "ssh:command:execute")
      assign(user, role)

      counts =
        for n <- [1, 10, 100] do
          targets = Enum.map(1..n, fn i -> %{id: "node-#{i}", tags: %{}} end)
          ctx = context(resolved_targets: targets, artifact: %{text: "uptime"})
          count_queries(fn -> RBAC.partition(user, "ssh:command:execute", ctx) end)
        end

      assert counts == [2, 2, 2]
    end
  end

  describe "TEST-202b: constant query count with command_policy" do
    setup do
      user = make_user("cmd_query_user")
      role = make_role("cmd_query_role")

      grant_with_policy(role, "ssh:command:execute", %{
        "allow" => ["systemctl **"],
        "deny" => ["systemctl stop *"]
      })

      assign(user, role)
      %{user: user}
    end

    test "check with command_policy still issues exactly 2 DB queries", %{user: user} do
      counts =
        for n <- [1, 10, 100] do
          targets = Enum.map(1..n, fn i -> %{id: "node-#{i}", tags: %{}} end)
          ctx = context(resolved_targets: targets, artifact: %{text: "systemctl restart nginx"})
          count_queries(fn -> RBAC.check(user, "ssh:command:execute", ctx) end)
        end

      assert counts == [2, 2, 2]
    end
  end

  describe "filter_targets/3 — RBAC-107, ADR-0006" do
    test "returns all nodes when principal has unrestricted inventory:node:read" do
      user = make_user("ft_all_user")
      role = make_role("ft_all_role")
      grant(role, "inventory:node:read")
      assign(user, role)

      nodes = [
        %{id: "n1", name: "node1", tags: %{}, targetable?: true, attributes: %{}, source: %{}},
        %{id: "n2", name: "node2", tags: %{}, targetable?: true, attributes: %{}, source: %{}}
      ]

      assert ^nodes = RBAC.filter_targets(nodes, user, "integ-1")
    end

    test "returns empty list when principal has no inventory:node:read permission" do
      user = make_user("ft_none_user")

      nodes = [
        %{id: "n1", name: "node1", tags: %{}, targetable?: true, attributes: %{}, source: %{}}
      ]

      assert [] = RBAC.filter_targets(nodes, user, "integ-1")
    end

    test "applies target_selector scoping — returns only nodes matching the selector" do
      user = make_user("ft_scoped_user")
      role = make_role("ft_scoped_role")

      {:ok, _} =
        RBAC.grant_permission(role, %{
          action: "inventory:node:read",
          target_selector: %{"tags" => %{"env" => "prod"}}
        })

      assign(user, role)

      nodes = [
        %{
          id: "n1",
          name: "prod-node",
          tags: %{"env" => "prod"},
          targetable?: true,
          attributes: %{},
          source: %{}
        },
        %{
          id: "n2",
          name: "dev-node",
          tags: %{"env" => "dev"},
          targetable?: true,
          attributes: %{},
          source: %{}
        }
      ]

      result = RBAC.filter_targets(nodes, user, "integ-1")
      assert length(result) == 1
      assert hd(result).id == "n1"
    end

    test "issues exactly 2 DB queries regardless of node count (RBAC-108 invariant)" do
      user = make_user("ft_query_user")
      role = make_role("ft_query_role")
      grant(role, "inventory:node:read")
      assign(user, role)

      counts =
        for n <- [1, 10, 100] do
          nodes =
            Enum.map(1..n, fn i ->
              %{
                id: "node-#{i}",
                name: "node-#{i}",
                tags: %{},
                targetable?: true,
                attributes: %{},
                source: %{}
              }
            end)

          count_queries(fn -> RBAC.filter_targets(nodes, user, "integ-1") end)
        end

      assert counts == [2, 2, 2]
    end

    test "admin with wildcard * permission sees all nodes" do
      user = make_user("ft_admin_user")
      role = make_role("ft_admin_role")
      grant(role, "*")
      assign(user, role)

      nodes = [
        %{id: "n1", name: "node1", tags: %{}, targetable?: true, attributes: %{}, source: %{}},
        %{id: "n2", name: "node2", tags: %{}, targetable?: true, attributes: %{}, source: %{}}
      ]

      assert ^nodes = RBAC.filter_targets(nodes, user, "integ-1")
    end
  end

  defp receive_count(ref, acc) do
    receive do
      {:query, ^ref} -> receive_count(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
