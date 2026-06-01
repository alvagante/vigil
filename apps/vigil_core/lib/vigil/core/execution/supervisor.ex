defmodule Vigil.Core.Execution.Supervisor do
  @moduledoc """
  DynamicSupervisor that owns one `Vigil.Core.Execution.Stream` GenServer per
  active `execution_group_id` (design §6.1). Each stream GenServer terminates
  normally after it persists its transcripts; the supervisor just ensures any
  crash during execution is isolated.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a `Vigil.Core.Execution.Stream` GenServer for the given group.
  `args` must include: `:runner_module`, `:integration_id`, `:artifact`,
  `:group_id`, and `:targets` (list of `%{execution_id, node_id}`).
  """
  def start_stream(args) do
    DynamicSupervisor.start_child(__MODULE__, {Vigil.Core.Execution.Stream, args})
  end
end
