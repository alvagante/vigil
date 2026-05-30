defmodule Vigil.Plugin.Permission do
  @moduledoc """
  An operational permission a plugin declares so admins can review what it does
  on enable (design §3.1: "filesystem paths read, executables invoked, network
  endpoints contacted, credentials used").

  NOTE: design §3 references `Vigil.Plugin.Permission.t()` in the
  `operational_permissions/0` callback but never specifies the struct's fields.
  This shape is inferred from that prose and is the canonical definition until
  the design doc is amended.
  """

  @type kind :: :filesystem | :executable | :network | :credential

  @enforce_keys [:kind, :description]
  defstruct [:kind, :description, detail: %{}]

  @type t :: %__MODULE__{
          kind: kind(),
          description: String.t(),
          detail: map()
        }
end
