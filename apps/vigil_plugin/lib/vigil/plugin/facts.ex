defmodule Vigil.Plugin.Facts do
  @moduledoc """
  The `:facts` capability contract (design §3.1.1).

  A plugin that declares `:facts` in `c:Vigil.Plugin.capabilities/0` implements
  this behaviour. Like every capability call it routes through
  `Vigil.Plugin.Dispatcher`, so the surface follows the uniform two-argument
  dispatch shape: the first argument is the integration ID and the second is an
  args map. The target node is carried in `args` under `:node` (the plugin's
  canonical node name, e.g. an SSH `Host` alias).

  The successful payload is a map of `fact_key => value`. Fact-value
  reconciliation across multiple sources is the unified-inventory concern (#22);
  a single plugin just reports what it gathered.
  """

  @type fact_map :: %{optional(String.t()) => term()}

  @doc """
  Gather facts for the node named in `args[:node]`. Returns the facts wrapped in
  a `Vigil.Plugin.Result` for source attribution, or a structured error (e.g.
  when the node is unknown or unreachable).
  """
  @callback get_facts(Vigil.Plugin.integration_id(), args :: map()) ::
              {:ok, Vigil.Plugin.Result.t()} | {:error, Vigil.Plugin.Error.t()}
end
