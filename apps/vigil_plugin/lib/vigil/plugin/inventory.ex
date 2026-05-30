defmodule Vigil.Plugin.Inventory do
  @moduledoc """
  The `:inventory` capability contract (design §3.1.1).

  A plugin that declares `:inventory` in `c:Vigil.Plugin.capabilities/0`
  implements this behaviour. The first argument is always the integration ID;
  operations return `{:ok, result} | {:error, error}` with the result wrapped
  in a `Vigil.Plugin.Result` for source attribution.
  """

  @callback list_nodes(Vigil.Plugin.integration_id(), opts :: map()) ::
              {:ok, Vigil.Plugin.Result.t()} | {:error, term()}
end
