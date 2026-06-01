defmodule VigilWeb.ExecutionTestPlugin do
  @moduledoc """
  Minimal in-test execution plugin for LiveView tests. Runner immediately
  completes, sending one chunk per target.
  """

  @behaviour Vigil.Plugin
  @behaviour Vigil.Plugin.Health
  @behaviour Vigil.Plugin.Execution.Runner

  alias Vigil.Plugin.{Schema}

  @plugin_id "exec_test"

  @impl Vigil.Plugin
  def plugin_id, do: @plugin_id
  @impl Vigil.Plugin
  def display_name, do: "Exec Test"
  @impl Vigil.Plugin
  def contract_version, do: Version.parse!("1.0.0")
  @impl Vigil.Plugin
  def capabilities, do: [:execution]
  @impl Vigil.Plugin
  def config_schema, do: %Schema{fields: []}
  @impl Vigil.Plugin
  def defaults, do: %{cache_ttl: %{}, timeouts: %{}, concurrency: 1}
  @impl Vigil.Plugin
  def operational_permissions, do: []

  @impl Vigil.Plugin
  def child_spec({integration_id, config}) do
    %{
      id: {:exec_test, integration_id},
      start: {__MODULE__.Server, :start_link, [{integration_id, config}]},
      type: :worker,
      restart: :temporary
    }
  end

  @impl Vigil.Plugin.Health
  def health_check(_integration_id), do: {:ok, :healthy}

  @impl Vigil.Plugin.Execution.Runner
  def start(_integration_id, _artifact, targets, opts) do
    stream_pid = Map.get(opts, :stream_pid)

    pid =
      spawn(fn ->
        Enum.each(targets, fn target ->
          if stream_pid do
            send(stream_pid, {:runner_chunk, target.execution_id, :text, "test output\n"})
            send(stream_pid, {:runner_target_done, target.execution_id, %{exit_status: 0, duration_ms: 1}})
          end
        end)

        if stream_pid, do: send(stream_pid, {:runner_done, %{}})
      end)

    {:ok, pid}
  end

  @impl Vigil.Plugin.Execution.Runner
  def abort(_runner_ref), do: :ok

  defmodule Server do
    @moduledoc false
    use GenServer

    def start_link({integration_id, _config}) do
      GenServer.start_link(__MODULE__, integration_id)
    end

    @impl true
    def init(integration_id) do
      {:ok, _} =
        Registry.register(
          Vigil.Plugin.Registry,
          {:integration, integration_id},
          VigilWeb.ExecutionTestPlugin
        )

      {:ok, integration_id}
    end
  end
end
