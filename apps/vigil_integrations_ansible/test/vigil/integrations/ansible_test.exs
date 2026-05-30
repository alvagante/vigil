defmodule Vigil.Integrations.AnsibleTest do
  use ExUnit.Case
  doctest Vigil.Integrations.Ansible

  test "greets the world" do
    assert Vigil.Integrations.Ansible.hello() == :world
  end
end
