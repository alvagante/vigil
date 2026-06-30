defmodule Vigil.Test.Fixtures.Generator do
  @moduledoc """
  Generates realistic scale fixture data for perf tests and cassette files.

  Called from `mix vigil.gen_fixtures` to (re)generate committed fixture files,
  and directly from :perf-tagged tests to seed in-memory test data.

  Per TEST-903, each generator injects awkward cases at realistic rates
  (missing attributes, deactivated nodes) so perf tests cover edge paths too.
  """

  @envs ["production", "staging", "development"]
  @statuses ["changed", "unchanged", "failed"]
  @catalog_statuses ["not_used", "used"]

  @doc """
  Generates `count` PuppetDB node records as a JSON-encoded string.

  Produced records match the `/pdb/query/v4/nodes` response shape. Injects
  ~1% deactivated nodes and ~2% nodes with nil `facts_timestamp` (TEST-903).
  """
  @spec puppetdb_nodes(count: pos_integer()) :: binary()
  def puppetdb_nodes(count: count) do
    nodes =
      for i <- 1..count do
        env = Enum.at(@envs, rem(i, length(@envs)))

        %{
          "certname" => "host-#{i}.#{env}.example.com",
          "deactivated" => nil,
          "catalog_timestamp" => random_iso8601(i, offset_range: 0..86_400),
          "facts_timestamp" => random_iso8601(i + 1, offset_range: 0..43_200),
          "report_timestamp" => random_iso8601(i + 2, offset_range: 0..7_200),
          "latest_report_status" => Enum.at(@statuses, rem(i, length(@statuses))),
          "latest_report_noop" => rem(i, 7) == 0,
          "cached_catalog_status" => Enum.at(@catalog_statuses, rem(i, 2))
        }
      end

    nodes
    |> inject_deactivated(rate: 0.01)
    |> inject_missing_facts(rate: 0.02)
    |> Jason.encode!()
  end

  ## Awkward-case injectors (TEST-903)

  defp inject_deactivated(nodes, rate: rate) do
    Enum.map(nodes, fn node ->
      if :erlang.phash2(node["certname"], 1000) < trunc(rate * 1000) do
        Map.put(node, "deactivated", deactivated_timestamp())
      else
        node
      end
    end)
  end

  defp inject_missing_facts(nodes, rate: rate) do
    Enum.map(nodes, fn node ->
      if :erlang.phash2({"mf", node["certname"]}, 1000) < trunc(rate * 1000) do
        Map.put(node, "facts_timestamp", nil)
      else
        node
      end
    end)
  end

  defp random_iso8601(seed, offset_range: range) do
    # Deterministic: same seed → same timestamp across runs
    base_unix = 1_751_000_000
    offset = rem(:erlang.phash2(seed, 1_000_000), Enum.count(range))
    unix = base_unix - offset
    unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  defp deactivated_timestamp do
    DateTime.from_unix!(1_750_900_000) |> DateTime.to_iso8601()
  end
end
