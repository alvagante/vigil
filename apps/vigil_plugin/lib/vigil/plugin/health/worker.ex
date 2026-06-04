defmodule Vigil.Plugin.Health.Worker do
  @moduledoc """
  Platform-managed periodic health probe for a single integration instance
  (design §3.6, PLUG-111, HEALTH-*).

  On each tick it calls `plugin_module.health_check/1`, then broadcasts
  `{:health, status, capabilities, diagnostic}` on topic
  `"integration_health:<integration_id>"` (design §2.6). The result is also
  broadcast on `"integration_health:all"` for rollup consumers (e.g., metrics).

  Probe interval defaults to 30 000 ms (`PLUG-111`). The worker registers
  itself under `{:health_worker, integration_id}` in `Vigil.Plugin.Registry`
  so `Vigil.Integrations.Manager` can terminate it by name.
  """

  use GenServer
  require Logger

  @default_interval_ms 30_000
  @pubsub_name Vigil.PubSub

  defstruct [:integration_id, :plugin_module, :interval_ms]

  ## Public API

  def start_link({integration_id, plugin_module, opts}) do
    GenServer.start_link(__MODULE__, {integration_id, plugin_module, opts})
  end

  def child_spec({integration_id, plugin_module, opts}) do
    %{
      id: {:health_worker, integration_id},
      start: {__MODULE__, :start_link, [{integration_id, plugin_module, opts}]},
      type: :worker,
      restart: :permanent
    }
  end

  ## GenServer callbacks

  @impl GenServer
  def init({integration_id, plugin_module, opts}) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    {:ok, _} =
      Registry.register(
        Vigil.Plugin.Registry,
        {:health_worker, integration_id},
        __MODULE__
      )

    state = %__MODULE__{
      integration_id: integration_id,
      plugin_module: plugin_module,
      interval_ms: interval_ms
    }

    # Probe immediately then on schedule
    send(self(), :check)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    perform_check(state)
    Process.send_after(self(), :check, state.interval_ms)
    {:noreply, state}
  end

  defp perform_check(%__MODULE__{} = state) do
    {status, diagnostic} =
      case state.plugin_module.health_check(state.integration_id) do
        {:ok, status} -> {status, %{}}
        {:error, error} -> {:unhealthy, %{error: inspect(error)}}
      end

    # Payload includes integration_id so subscribers can route without topic metadata.
    # Design §2.6 lists `{:health, status, capabilities, diagnostic}` — we extend to
    # `{:health, integration_id, status, capabilities, diagnostic}` for LiveView routing.
    payload =
      {:health, state.integration_id, status, state.plugin_module.capabilities(), diagnostic}

    topic = "integration_health:#{state.integration_id}"

    Phoenix.PubSub.broadcast(@pubsub_name, topic, payload)
    Phoenix.PubSub.broadcast(@pubsub_name, "integration_health:all", payload)

    Logger.debug("[health:worker] integration=#{state.integration_id} status=#{status}")

    # Mirror latest health into the DB row for fast initial page renders (§4.3.5).
    # Gracefully skip if the row is unavailable (e.g., outside the Ecto sandbox in tests).
    try do
      Vigil.Core.IntegrationConfig.update_health(state.integration_id, %{
        "status" => Atom.to_string(status),
        "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    rescue
      _ -> :ok
    end
  end
end
