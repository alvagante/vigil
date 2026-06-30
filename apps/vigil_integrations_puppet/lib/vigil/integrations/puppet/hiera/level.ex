defmodule Vigil.Integrations.Puppet.Hiera.Level do
  @moduledoc false

  @enforce_keys [:name, :data_source_path]
  defstruct [:name, :data_source_path, backend: :yaml, options: %{}]
end
