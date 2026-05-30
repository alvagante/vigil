defmodule Vigil.Plugin.Schema do
  @moduledoc """
  A small declarative DSL for plugin configuration schemas (design §3.2.3) —
  not a library, just a struct. Plugins return one from `c:Vigil.Plugin.config_schema/0`;
  `validate/2` (added with the plugin-lifecycle issue #5) checks a config map
  against it and the settings LiveView renders fields directly from it.
  """

  defstruct fields: []

  @type t :: %__MODULE__{fields: [__MODULE__.Field.t()]}

  defmodule Field do
    @moduledoc "A single configuration field declaration."

    defstruct [
      :name,
      :type,
      :required,
      :default,
      :secret?,
      :validators,
      :description,
      :conditional_on
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            type: atom(),
            required: boolean() | nil,
            default: term(),
            secret?: boolean() | nil,
            validators: list() | nil,
            description: String.t() | nil,
            conditional_on: term()
          }
  end
end
