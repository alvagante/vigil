defmodule Vigil.Integrations.SSH.MixProject do
  use Mix.Project

  def project do
    [
      app: :vigil_integrations_ssh,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # `:vigil_plugin` env makes this OTP app discoverable by
      # `Vigil.Plugin.Catalog` (design §3.2.1): the catalog scans loaded apps
      # for this key and maps the module's `plugin_id/0` to the module.
      env: [vigil_plugin: Vigil.Integrations.SSH],
      extra_applications: [:logger, :ssh]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:vigil_plugin, in_umbrella: true},
      {:jason, "~> 1.2"}
    ]
  end
end
