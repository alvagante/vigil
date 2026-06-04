defmodule Vigil.Integrations.Bolt.TypeParserTest do
  use ExUnit.Case, async: true

  alias Vigil.Integrations.Bolt.TypeParser

  describe "widget_type/1 — Puppet type string → widget kind (BOLT-203)" do
    test "Boolean → :boolean" do
      assert TypeParser.widget_type("Boolean") == :boolean
    end

    test "Optional[Boolean] → :boolean" do
      assert TypeParser.widget_type("Optional[Boolean]") == :boolean
    end

    test "Integer[1] → :integer" do
      assert TypeParser.widget_type("Integer[1]") == :integer
    end

    test "Optional[Integer[0, default=8]] → :integer" do
      assert TypeParser.widget_type("Optional[Integer[0, default=8]]") == :integer
    end

    test "Enum[running, stopped] → :enum" do
      assert TypeParser.widget_type("Enum[running, stopped]") == :enum
    end

    test "Optional[Enum[present, absent, purged]] → :enum" do
      assert TypeParser.widget_type("Optional[Enum[present, absent, purged]]") == :enum
    end

    test "String → :string" do
      assert TypeParser.widget_type("String") == :string
    end

    test "Optional[String[1]] → :string" do
      assert TypeParser.widget_type("Optional[String[1]]") == :string
    end

    test "unknown type → :string (fallback)" do
      assert TypeParser.widget_type("Variant[String, Integer]") == :string
    end
  end

  describe "parse_enum_values/1 — Puppet Enum type → value list (BOLT-203)" do
    test "Enum[a, b, c] → [\"a\", \"b\", \"c\"]" do
      assert TypeParser.parse_enum_values("Enum[running, stopped]") == ["running", "stopped"]
    end

    test "Optional[Enum[...]] → value list" do
      assert TypeParser.parse_enum_values("Optional[Enum[present, absent, purged]]") ==
               ["present", "absent", "purged"]
    end

    test "non-enum returns []" do
      assert TypeParser.parse_enum_values("String") == []
      assert TypeParser.parse_enum_values("Boolean") == []
    end
  end

  describe "strip_optional/1 — removes Optional[] wrapper (BOLT-203)" do
    test "Optional[Boolean] → Boolean" do
      assert TypeParser.strip_optional("Optional[Boolean]") == "Boolean"
    end

    test "Optional[Enum[a, b]] → Enum[a, b]" do
      assert TypeParser.strip_optional("Optional[Enum[a, b]]") == "Enum[a, b]"
    end

    test "bare type unchanged" do
      assert TypeParser.strip_optional("String") == "String"
      assert TypeParser.strip_optional("Integer[1]") == "Integer[1]"
    end
  end
end
