defmodule Vigil.Plugin do
  @moduledoc """
  The contract every integration plugin implements (design §3.1).

  A plugin is an OTP application that registers a top-level module implementing
  this behaviour. The platform discovers plugins at startup and uses them to
  build supervision trees for each configured integration instance.

  The behaviour is intentionally small; plugins compose substantial
  implementations on top of it via per-capability behaviours
  (`Vigil.Plugin.Inventory`, ...).
  """

  @type integration_id :: String.t()
  @type config :: map()

  @type capability ::
          :inventory
          | :facts
          | :configuration
          | :events
          | :monitoring
          | :reports
          | :execution
          | :provisioning
          | :deployment

  @doc "Stable plugin identifier (e.g., \"puppet\"). MUST NOT change across versions."
  @callback plugin_id() :: String.t()

  @doc "Human-readable plugin name for UI display."
  @callback display_name() :: String.t()

  @doc "Plugin contract version this plugin targets."
  @callback contract_version() :: Version.t()

  @doc "List of capabilities this plugin provides."
  @callback capabilities() :: [capability()]

  @doc "Configuration schema as a `Vigil.Plugin.Schema`."
  @callback config_schema() :: Vigil.Plugin.Schema.t()

  @doc "Default TTLs, timeouts, and concurrency budget per capability."
  @callback defaults() :: %{
              cache_ttl: %{capability() => pos_integer()},
              timeouts: %{capability() => pos_integer()},
              concurrency: pos_integer()
            }

  @doc """
  Operational permissions to show admins on enable: filesystem paths read,
  executables invoked, network endpoints contacted, credentials used.
  """
  @callback operational_permissions() :: [Vigil.Plugin.Permission.t()]

  @doc """
  Returns a child spec for the supervision tree of a single integration
  instance. The platform calls this for each configured instance and starts the
  subtree under `Vigil.Integrations.Supervisor`. The subtree is responsible for
  registering the instance under `{:integration, integration_id}` in
  `Vigil.Plugin.Registry` so the dispatcher can resolve it.
  """
  @callback child_spec({integration_id(), config()}) :: Supervisor.child_spec()
end
