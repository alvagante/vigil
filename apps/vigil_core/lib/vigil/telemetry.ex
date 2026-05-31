defmodule Vigil.Telemetry.Supervisor do
  @moduledoc false
  use Supervisor
  import Telemetry.Metrics

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ reporters()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp reporters do
    if Mix.env() == :test do
      []
    else
      [{Telemetry.Metrics.ConsoleReporter, metrics: metrics()}]
    end
  end

  def metrics do
    [
      summary("vigil.repo.query.total_time", unit: {:native, :millisecond}),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    []
  end
end
