defmodule Vigil.Integrations.Puppet.Report do
  @moduledoc false

  @enforce_keys [:certname, :hash]
  defstruct [
    :certname,
    :hash,
    :status,
    :start_time,
    :end_time,
    :run_duration,
    :num_changes,
    :num_failures,
    :num_corrective_changes,
    :num_skips,
    :num_noops,
    :noop,
    :environment,
    :catalog_uuid,
    :code_id
  ]
end
