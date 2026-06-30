defmodule Vigil.Integrations.Puppet.Resource do
  @moduledoc false

  @enforce_keys [:type, :title]
  defstruct [:type, :title, :parameters, :tags, :file, :line, exported: false]
end
