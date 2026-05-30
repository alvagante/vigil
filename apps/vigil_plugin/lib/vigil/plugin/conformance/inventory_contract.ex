defmodule Vigil.Plugin.Conformance.InventoryContract do
  @moduledoc """
  Asserts the `:inventory` capability dispatches through `Vigil.Plugin.Dispatcher`
  and returns a well-formed `Vigil.Plugin.Result` with source attribution.
  """

  alias Vigil.Plugin.{Dispatcher, Result}
  alias Vigil.Plugin.Conformance.Check

  @spec run(map()) :: [Check.t()]
  def run(%{integration_id: integration_id}) do
    name = "inventory:list_nodes/2:result_shape"

    case Dispatcher.call(integration_id, :inventory, :list_nodes, %{}) do
      {:ok, %Result{source: source, fetched_at: %DateTime{}}} when not is_nil(source) ->
        if source.integration_id == integration_id do
          [Check.pass(name)]
        else
          [Check.fail(name, "Result.source.integration_id did not match the called integration")]
        end

      {:ok, other} ->
        [Check.fail(name, "list_nodes returned a malformed Result: #{inspect(other)}")]

      {:error, error} ->
        [Check.fail(name, "list_nodes returned an error: #{inspect(error)}")]
    end
  end
end
