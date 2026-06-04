defmodule Vigil.Integrations.Bolt.TypeParser do
  @moduledoc false

  @doc """
  Maps a Bolt/Puppet type string to a widget kind for form rendering.
  Strips any Optional[] wrapper before checking the bare type.
  """
  def widget_type(type) do
    bare = strip_optional(type)

    cond do
      String.starts_with?(bare, "Boolean") -> :boolean
      String.starts_with?(bare, "Integer") -> :integer
      String.starts_with?(bare, "Enum[") -> :enum
      true -> :string
    end
  end

  @doc """
  Extracts enum value strings from a Puppet Enum or Optional[Enum[...]] type string.
  Returns [] for non-enum types.
  """
  def parse_enum_values("Optional[Enum[" <> rest) do
    rest |> String.trim_trailing("]]") |> String.split(", ") |> Enum.map(&String.trim/1)
  end

  def parse_enum_values("Enum[" <> rest) do
    rest |> String.trim_trailing("]") |> String.split(", ") |> Enum.map(&String.trim/1)
  end

  def parse_enum_values(_), do: []

  @doc """
  Strips the Optional[] wrapper from a Puppet type string, returning the bare type.
  """
  def strip_optional("Optional[" <> rest), do: String.slice(rest, 0..-2//1)
  def strip_optional(type), do: type
end
