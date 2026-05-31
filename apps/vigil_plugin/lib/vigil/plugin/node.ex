defmodule Vigil.Plugin.Node do
  @moduledoc """
  A single inventory node as a plugin reports it (design §3.1.1, referenced by
  the `Vigil.Plugin.Inventory` callback return types).

  `name` is the plugin's canonical identifier for the node within its own
  namespace (for SSH, the `Host` alias). `attributes` carries source-specific
  connection/identity metadata. `targetable?` is `false` for entries that are
  configuration directives rather than executable destinations — e.g. SSH
  wildcard `Host` patterns (`SSH-103`); the UI must not offer execute actions
  against them.

  Cross-source identity reconciliation (matching this node to nodes from other
  integrations) is deferred to the unified-inventory work (#22); for now a node
  stands on its own, attributed to the `Vigil.Plugin.Result` it travels in.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            display_name: nil,
            attributes: %{},
            targetable?: true

  @type t :: %__MODULE__{
          name: String.t(),
          display_name: String.t() | nil,
          attributes: map(),
          targetable?: boolean()
        }
end
