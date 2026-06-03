defmodule Vigil.Core.RBAC.GlobPolicyTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.RBAC.GlobPolicy

  describe "compile!/1" do
    test "literal pattern matches the exact command" do
      regex = GlobPolicy.compile!("systemctl restart nginx")
      assert Regex.match?(regex, "systemctl restart nginx")
      refute Regex.match?(regex, "systemctl restart postgres")
    end

    test ". in pattern is a literal dot" do
      regex = GlobPolicy.compile!("systemctl restart nginx.service")
      assert Regex.match?(regex, "systemctl restart nginx.service")
      refute Regex.match?(regex, "systemctl restart nginxXservice")
    end

    test "* matches within a single token but not across spaces" do
      regex = GlobPolicy.compile!("systemctl restart *")
      assert Regex.match?(regex, "systemctl restart nginx")
      assert Regex.match?(regex, "systemctl restart nginx.service")
      refute Regex.match?(regex, "systemctl restart nginx postgres")
    end

    test "** matches across argument boundaries" do
      regex = GlobPolicy.compile!("systemctl ** nginx")
      assert Regex.match?(regex, "systemctl restart nginx")
      assert Regex.match?(regex, "systemctl --user start nginx")
    end

    test "? matches exactly one character" do
      regex = GlobPolicy.compile!("ls -?")
      assert Regex.match?(regex, "ls -l")
      assert Regex.match?(regex, "ls -a")
      refute Regex.match?(regex, "ls -la")
      refute Regex.match?(regex, "ls -")
    end

    test "raises ArgumentError on regex metacharacters" do
      for bad <- ["(foo)", "[abc]", "a+b", "a{2}", "a|b", "a\\b"] do
        assert_raise ArgumentError, ~r/glob syntax/, fn ->
          GlobPolicy.compile!(bad)
        end
      end
    end

    test "compile! does not allow ^ or $ anchors in the pattern itself" do
      assert_raise ArgumentError, ~r/glob syntax/, fn ->
        GlobPolicy.compile!("^start")
      end

      assert_raise ArgumentError, ~r/glob syntax/, fn ->
        GlobPolicy.compile!("end$")
      end
    end
  end

  describe "matches?/2" do
    test "nil policy permits all commands" do
      assert GlobPolicy.matches?(nil, "rm -rf /")
      assert GlobPolicy.matches?(nil, "")
    end

    test "empty allow list is open — any non-blocked command is permitted" do
      policy = %{"allow" => [], "deny" => []}
      assert GlobPolicy.matches?(policy, "any command here")
      assert GlobPolicy.matches?(policy, "rm -rf /")
    end

    test "non-empty allow list is closed — command must match an allow pattern" do
      policy = %{"allow" => ["systemctl restart *"], "deny" => []}
      assert GlobPolicy.matches?(policy, "systemctl restart nginx")
      refute GlobPolicy.matches?(policy, "rm -rf /")
      refute GlobPolicy.matches?(policy, "systemctl stop nginx")
    end

    test "deny list blocks commands regardless of allow" do
      policy = %{"allow" => ["systemctl **"], "deny" => ["systemctl stop *"]}
      assert GlobPolicy.matches?(policy, "systemctl restart nginx")
      refute GlobPolicy.matches?(policy, "systemctl stop nginx")
    end

    test "deny wins when command matches both allow and deny (EXEC-305)" do
      policy = %{"allow" => ["**"], "deny" => ["rm **"]}
      assert GlobPolicy.matches?(policy, "ls -la")
      refute GlobPolicy.matches?(policy, "rm -rf /")
    end
  end
end
