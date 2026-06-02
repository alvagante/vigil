defmodule Vigil.Core.RBAC.Context do
  @moduledoc """
  Carries the resolved action context for a permission check.
  Targets must be pre-loaded by the caller — the Evaluator never queries DB per target.
  """
  defstruct integration_id: nil, resolved_targets: [], artifact: nil
end
