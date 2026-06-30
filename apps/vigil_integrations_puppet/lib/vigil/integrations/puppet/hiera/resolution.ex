defmodule Vigil.Integrations.Puppet.Hiera.Resolution do
  @moduledoc false

  @enforce_keys [:key, :merge_strategy]
  defstruct [:key, :result, :merge_strategy, chain: []]
end
