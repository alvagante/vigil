defmodule Vigil.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, ">= 0.0.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # The release must enumerate every OTP app explicitly. `vigil_web` only
  # depends on `vigil_core` + `vigil_plugin`, so the integration apps and
  # `vigil_auth_oidc` are siblings outside its dependency graph. A default
  # umbrella release would compile but NOT boot them, leaving
  # `Vigil.Plugin.Catalog` with zero plugins in production.
  defp releases do
    [
      vigil: [
        version: @version,
        applications: [
          vigil_core: :permanent,
          vigil_plugin: :permanent,
          vigil_auth_oidc: :permanent,
          vigil_integrations_puppet: :permanent,
          vigil_integrations_bolt: :permanent,
          vigil_integrations_ansible: :permanent,
          vigil_integrations_ssh: :permanent,
          vigil_integrations_proxmox: :permanent,
          vigil_web: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp aliases do
    [
      setup: ["cmd mix setup"],
      "ecto.setup": ["do --app vigil_core ecto.setup"],
      "ecto.reset": ["do --app vigil_core ecto.reset"],
      test: [
        "do --app vigil_core ecto.create --quiet",
        "do --app vigil_core ecto.migrate --quiet",
        "test"
      ],
      # Build assets and assemble the production release.
      "assets.deploy": ["cmd --app vigil_web mix assets.deploy"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
