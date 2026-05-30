defmodule Vigil.Plugin.Health do
  @moduledoc """
  The health-check lifecycle hook (design §3.6, PLUG-111). Distinct from the
  capability call path: a periodic probe worker invokes `health_check/1` to
  determine whether an integration instance is reachable and usable. A plugin
  declares its initialization success via its first successful probe.
  """

  @type status :: :healthy | :degraded | :unhealthy

  @callback health_check(Vigil.Plugin.integration_id()) ::
              {:ok, status()} | {:error, Vigil.Plugin.Error.t()}
end
