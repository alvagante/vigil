defmodule Vigil.Integrations.Puppet.CatalogDiff do
  @moduledoc false

  defstruct only_in_a: [], only_in_b: [], changed: [], identical_count: 0
end
