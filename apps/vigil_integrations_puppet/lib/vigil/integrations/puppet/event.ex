defmodule Vigil.Integrations.Puppet.Event do
  @moduledoc false

  @enforce_keys [:source_event_id, :group_key, :entry_type, :severity]
  defstruct [
    :source_event_id,
    :occurred_at,
    :entry_type,
    :summary,
    :severity,
    :detail,
    :group_key,
    :references
  ]
end
