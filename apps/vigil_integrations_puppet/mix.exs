defmodule Vigil.Integrations.Puppet.MixProject do
  use Mix.Project

  def project do
    [
      app: :vigil_integrations_puppet,
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Vigil.Integrations.Puppet.Application, []},
      env: [vigil_plugin: Vigil.Integrations.Puppet],
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:vigil_plugin, in_umbrella: true},
      {:finch, "~> 0.19"},
      {:jason, "~> 1.2"}
    ]
  end
end
