defmodule Vigil.Plugin.Conformance.Report do
  @moduledoc """
  Structured result of a conformance run (design §3.7): passes, failures, and
  warnings. Returned by `Vigil.Plugin.Conformance.run/2` — the runner never
  calls test assertions, so the same report drives the test suite, startup
  Validation mode, and sibling plugin apps' own suites.
  """

  alias Vigil.Plugin.Conformance.Check

  @enforce_keys [:plugin]
  defstruct plugin: nil, passed: [], failed: [], warnings: []

  @type t :: %__MODULE__{
          plugin: module(),
          passed: [Check.t()],
          failed: [Check.t()],
          warnings: [Check.t()]
        }

  @doc "Build a report by partitioning checks by status."
  @spec from_checks(module(), [Check.t()]) :: t()
  def from_checks(plugin, checks) do
    %__MODULE__{
      plugin: plugin,
      passed: Enum.filter(checks, &(&1.status == :pass)),
      failed: Enum.filter(checks, &(&1.status == :fail)),
      warnings: Enum.filter(checks, &(&1.status == :warn))
    }
  end

  @doc "True when the plugin conforms — no failed checks. Warnings do not fail conformance."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{failed: []}), do: true
  def ok?(%__MODULE__{}), do: false
end
