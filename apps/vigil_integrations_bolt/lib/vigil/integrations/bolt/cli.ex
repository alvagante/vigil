defmodule Vigil.Integrations.Bolt.CLI do
  @moduledoc """
  Behaviour for invoking the Bolt CLI (EXEC-CLI-002).

  The real implementation (`CLI.Port`) opens an OS port. Tests use
  `FakeCLI` to script responses without a real `bolt` binary.
  """

  @type result :: %{exit_status: integer(), stdout: String.t(), stderr: String.t()}

  @callback run(executable :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, result()} | {:error, :not_found | :timeout | term()}
end
