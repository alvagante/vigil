defmodule Vigil.Plugin.Result do
  @moduledoc """
  Wrapper carrying a plugin's payload plus source attribution and freshness
  metadata. Every successful capability call returns one of these (design §3.1.2).
  """

  @enforce_keys [:data, :source, :fetched_at]
  defstruct data: nil,
            source: nil,
            fetched_at: nil,
            freshness: :live,
            partial?: false,
            continuation: nil

  @type freshness :: :live | :cached | :stale

  @type t :: %__MODULE__{
          data: term(),
          source: Vigil.Plugin.Source.t(),
          fetched_at: DateTime.t(),
          freshness: freshness(),
          partial?: boolean(),
          continuation: term()
        }
end
