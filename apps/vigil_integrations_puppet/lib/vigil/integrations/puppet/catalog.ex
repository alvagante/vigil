defmodule Vigil.Integrations.Puppet.Catalog do
  @moduledoc false

  @enforce_keys [:certname]
  defstruct [:certname, :environment, :version, resources: [], edges: []]
end
