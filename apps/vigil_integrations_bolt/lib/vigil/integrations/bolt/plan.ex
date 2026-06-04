defmodule Vigil.Integrations.Bolt.Plan do
  @moduledoc """
  Represents a Bolt plan with optional parameter metadata (BOLT-204).

  `parameters` is `nil` until populated by `Bolt.show_plan/3`.
  """

  defstruct [:name, :description, :parameters]

  @type param :: %{
          name: String.t(),
          type: String.t(),
          required: boolean(),
          sensitive: boolean(),
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          parameters: [param()] | nil
        }
end
