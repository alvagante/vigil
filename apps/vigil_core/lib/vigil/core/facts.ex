defmodule Vigil.Core.Facts do
  @moduledoc """
  Pure construction of the source-badged facts table (design §9.7.1,
  `PLUG-503` / `UI-308`).

  This module takes facts **already fetched** from plugins (the Dispatcher fan-out
  lives in the web layer, since `vigil_core` must not call down into
  `vigil_plugin`) and shapes them into `Row`s for rendering. Every row carries
  its source attribution.

  For now only a single source contributes facts to a node, so `rows_from_source/2`
  is the whole surface. Multi-source collapsing — grouping by `{key, value}` so
  that two integrations agreeing on a value share a row, and conflicting values
  appear as separate rows — arrives with unified inventory (#22) as
  `unified_rows/2`.
  """

  alias __MODULE__.Row

  defmodule Row do
    @moduledoc "One row of the facts table: a key, its value, and the sources reporting it."

    @enforce_keys [:key, :value, :sources]
    defstruct key: nil, value: nil, sources: []

    @type source :: %{
            plugin_id: String.t(),
            integration_id: String.t(),
            integration_name: String.t(),
            gathered_at: DateTime.t() | nil
          }

    @type t :: %__MODULE__{key: String.t(), value: term(), sources: [source()]}
  end

  @doc """
  Build the rows contributed by a single source's fact map, sorted by key.
  Each row is attributed to `source`.
  """
  @spec rows_from_source(map(), Row.source()) :: [Row.t()]
  def rows_from_source(facts, source) when is_map(facts) do
    facts
    |> Enum.map(fn {key, value} -> %Row{key: key, value: value, sources: [source]} end)
    |> Enum.sort_by(& &1.key)
  end
end
