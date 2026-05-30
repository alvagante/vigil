defmodule Vigil.Plugin.Conformance.Check do
  @moduledoc "A single conformance assertion result."

  @enforce_keys [:name, :status]
  defstruct [:name, :status, :message]

  @type status :: :pass | :fail | :warn
  @type t :: %__MODULE__{name: String.t(), status: status(), message: String.t() | nil}

  @doc "A passing check."
  def pass(name), do: %__MODULE__{name: name, status: :pass}

  @doc "A failing check with a diagnostic message."
  def fail(name, message), do: %__MODULE__{name: name, status: :fail, message: message}

  @doc "A warning — e.g., a declared capability with no conformance contract yet."
  def warn(name, message), do: %__MODULE__{name: name, status: :warn, message: message}
end
