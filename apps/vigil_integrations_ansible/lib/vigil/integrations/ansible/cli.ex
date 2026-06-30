defmodule Vigil.Integrations.Ansible.CLI do
  @moduledoc """
  Transport behaviour for Ansible CLI calls.

  The real implementation (`CLI.Port`) shells out to the `ansible`,
  `ansible-inventory`, and `ansible-playbook` binaries. Tests inject
  `FakeCLI` via `config["cli_module"]`.

  All implementations return `{:ok, %{exit_status: non_neg_integer(), stdout: String.t()}}` on
  execution (even when the command itself fails — exit_status carries that), or
  `{:error, reason}` when the binary is not found or the process times out.
  """

  @callback run(executable :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, %{exit_status: non_neg_integer(), stdout: String.t()}} | {:error, term()}
end
