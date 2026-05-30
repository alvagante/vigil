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
      :conditional_on,
      # :hot   — field can be updated without restarting the integration supervisor
      # :restart — field change requires a supervisor restart to take effect
      # nil    — reload behaviour unspecified (treated as :restart for safety)
      :reload
    ]

    @type reload :: :hot | :restart
    @type t :: %__MODULE__{
            name: String.t(),
            type: atom(),
            required: boolean() | nil,
            default: term(),
            secret?: boolean() | nil,
            validators: list() | nil,
            description: String.t() | nil,
            conditional_on: term(),
            reload: reload() | nil
          }
  end

  @doc """
  Validate `config` against the schema, returning `{:ok, config}` on success or
  `{:error, [field_errors]}` on failure. Each error is `{field_name, message}`.
  """
  @spec validate(t(), map()) :: {:ok, map()} | {:error, [{String.t(), String.t()}]}
  def validate(%__MODULE__{fields: fields}, config) do
    errors =
      Enum.flat_map(fields, fn field ->
        value = Map.get(config, field.name)

        cond do
          field.required && is_nil(value) ->
            [{field.name, "is required"}]

          not is_nil(value) && not valid_type?(field.type, value) ->
            [{field.name, "invalid value for type #{field.type}"}]

          true ->
            []
        end
      end)

    if errors == [], do: {:ok, config}, else: {:error, errors}
  end

  defp valid_type?(:string, v), do: is_binary(v)
  defp valid_type?(:integer, v), do: is_integer(v)
  defp valid_type?(:boolean, v), do: is_boolean(v)
  defp valid_type?(:url, v), do: is_binary(v) and String.starts_with?(v, ["http://", "https://"])
  defp valid_type?(:path_or_secret_ref, v), do: is_binary(v)
  defp valid_type?(_type, _v), do: true
end
