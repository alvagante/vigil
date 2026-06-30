defmodule Mix.Tasks.Vigil.GenFixtures do
  @shortdoc "Regenerate committed scale fixture files for perf tests"

  @moduledoc """
  Generates or regenerates the scale fixture cassette files used by the
  :perf-tagged test suite (TEST-901..903, §13.3.10).

  Run from the umbrella root:

      mix vigil.gen_fixtures

  The generated files are committed to the repository. Re-run when the upstream
  API response shape changes or when realistic data shapes need updating. CI
  never re-generates — it uses the committed files.

  Generated files:
  - test/fixtures/cassettes/puppet/nodes_100.json   (100 PuppetDB nodes)
  - test/fixtures/cassettes/puppet/nodes_10k.json   (10,000 PuppetDB nodes)
  """

  use Mix.Task

  alias Vigil.Test.Fixtures.Generator

  @fixtures_dir "test/fixtures/cassettes"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Generating scale fixtures in #{@fixtures_dir}/")

    generate("puppet/nodes_100.json", fn -> Generator.puppetdb_nodes(count: 100) end)
    generate("puppet/nodes_10k.json", fn -> Generator.puppetdb_nodes(count: 10_000) end)

    Mix.shell().info("Done.")
  end

  defp generate(relative_path, generator_fn) do
    dest = Path.join(@fixtures_dir, relative_path)
    File.mkdir_p!(Path.dirname(dest))

    Mix.shell().info("  Generating #{dest} ...")
    content = generator_fn.()
    File.write!(dest, content)
    Mix.shell().info("  Written #{byte_size(content)} bytes -> #{dest}")
  end
end
