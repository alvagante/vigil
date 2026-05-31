defmodule Vigil.Plugin.MixProject do
  use Mix.Project

  def project do
    [
      app: :vigil_plugin,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Vigil.Plugin.Application, []}
    ]
  end

  # The reference no-op plugin (PLUG-702) is compiled only in the test env; it
  # exercises the platform contract without shipping in releases.
  defp elixirc_paths(:test), do: ["lib", "test/reference_plugin"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:vigil_core, in_umbrella: true}
    ]
  end
end
