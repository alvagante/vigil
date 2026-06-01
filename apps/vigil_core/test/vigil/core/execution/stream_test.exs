defmodule Vigil.Core.Execution.StreamTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Execution.Stream

  describe "cap_transcript/2" do
    test "returns transcript unchanged when under the cap" do
      data = "normal output\n"
      assert Stream.cap_transcript(data, 100) == data
    end

    test "truncates at cap and appends a truncation marker when over the cap" do
      data = String.duplicate("x", 200)
      result = Stream.cap_transcript(data, 100)

      assert byte_size(result) > 100
      assert String.starts_with?(result, String.duplicate("x", 100))
      assert result =~ "TRUNCATED"
    end

    test "defaults cap to 50 MB" do
      small = "small"
      assert Stream.cap_transcript(small) == small
    end
  end
end
