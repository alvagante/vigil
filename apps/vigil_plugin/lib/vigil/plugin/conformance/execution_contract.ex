defmodule Vigil.Plugin.Conformance.ExecutionContract do
  @moduledoc """
  Asserts the `:execution` capability honours the `Vigil.Plugin.Execution.Runner`
  contract (design §6.3): `start/4` yields an opaque runner reference and
  `abort/1` stops it cleanly. The streaming machinery itself is exercised by the
  execution issues (#7, #13, #15); here we pin only the contract shape.
  """

  alias Vigil.Plugin.Conformance.Check

  @spec run(map()) :: [Check.t()]
  def run(%{plugin: plugin, integration_id: integration_id}) do
    [start_and_abort(plugin, integration_id)]
  end

  defp start_and_abort(plugin, integration_id) do
    name = "execution:start/4:shape"

    with true <- function_exported?(plugin, :start, 4) or {:missing, :start, 4},
         true <- function_exported?(plugin, :abort, 1) or {:missing, :abort, 1},
         {:ok, runner_ref} <- plugin.start(integration_id, %{}, [], %{}),
         :ok <- plugin.abort(runner_ref) do
      Check.pass(name)
    else
      {:missing, fun, arity} ->
        Check.fail(name, "#{inspect(plugin)} does not implement Runner.#{fun}/#{arity}")

      {:error, reason} ->
        Check.fail(name, "start/4 returned an error: #{inspect(reason)}")

      other ->
        Check.fail(name, "execution runner contract violated: #{inspect(other)}")
    end
  end
end
