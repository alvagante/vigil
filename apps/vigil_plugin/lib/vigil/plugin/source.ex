defmodule Vigil.Plugin.Source do
  @moduledoc """
  Attribution attached to every value a plugin returns: which plugin produced
  it, and which configured integration instance it came from.
  """

  @enforce_keys [:plugin_id, :integration_id]
  defstruct plugin_id: nil, integration_id: nil

  @type t :: %__MODULE__{
          plugin_id: String.t(),
          integration_id: Vigil.Plugin.integration_id()
        }
end
