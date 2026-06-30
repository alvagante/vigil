defmodule Vigil.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, ">= 0.0.0"}
    ]
  end

  defp releases do
    [
      vigil: [
        include_executables_for: [:unix],
        applications: [
          vigil_core: :permanent,
          vigil_plugin: :permanent,
          vigil_auth_oidc: :permanent,
          vigil_integrations_ansible: :permanent,
          vigil_integrations_bolt: :permanent,
          vigil_integrations_proxmox: :permanent,
          vigil_integrations_puppet: :permanent,
          vigil_integrations_ssh: :permanent,
          vigil_web: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["cmd mix setup"],
      "ecto.setup": ["do --app vigil_core ecto.setup"],
      "ecto.reset": ["do --app vigil_core ecto.reset"],
      "assets.deploy": ["cmd --app vigil_web mix assets.deploy"],
      test: [
        "do --app vigil_core ecto.create --quiet",
        "do --app vigil_core ecto.migrate --quiet",
        "test"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
