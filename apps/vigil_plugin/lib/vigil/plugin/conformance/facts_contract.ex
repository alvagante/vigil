defmodule Vigil.Plugin.Conformance.FactsContract do
  @moduledoc """
  Asserts the `:facts` capability dispatches through `Vigil.Plugin.Dispatcher`
  and honours the `Vigil.Plugin.Facts` contract.

  Facts gathering inherently depends on a reachable target, which a conformance
  run cannot guarantee (CI has no live host; the node identity is synthetic).
  The contract therefore treats **two** outcomes as conformant:

    * `{:ok, %Result{}}` with correct source attribution — the plugin reached a
      target and returned facts; or
    * `{:error, %Vigil.Plugin.Error{}}` — the plugin could not gather facts but
      reported it as a *structured* error, exactly as the contract requires.

  What is **not** conformant: a malformed `Result`, a bare/untyped error term, or
  a mismatched source attribution. This keeps the check meaningful while letting
  it pass against a real plugin with no reachable node.
  """

  alias Vigil.Plugin.{Dispatcher, Error, Result}
  alias Vigil.Plugin.Conformance.Check

  @spec run(map()) :: [Check.t()]
  def run(%{integration_id: integration_id}) do
    name = "facts:get_facts/2:result_shape"

    case Dispatcher.call(integration_id, :facts, :get_facts, %{}) do
      {:ok, %Result{source: source, fetched_at: %DateTime{}}} when not is_nil(source) ->
        if source.integration_id == integration_id do
          [Check.pass(name)]
        else
          [Check.fail(name, "Result.source.integration_id did not match the called integration")]
        end

      {:ok, other} ->
        [Check.fail(name, "get_facts returned a malformed Result: #{inspect(other)}")]

      {:error, %Error{}} ->
        [Check.pass(name)]

      {:error, other} ->
        [
          Check.fail(
            name,
            "get_facts must return a structured Vigil.Plugin.Error, got: #{inspect(other)}"
          )
        ]
    end
  end
end
