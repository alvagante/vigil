defmodule Vigil.Plugin.Execution.Runner do
  @moduledoc """
  The `:execution` capability contract (design §6.3). Unlike read capabilities,
  execution is a streaming concern: a runner is a process started by the Stream
  GenServer that owns the port / HTTP long-poll against the external tool and
  streams chunks back. This behaviour is the contract surface; the streaming
  machinery (Stream GenServer, checkpointing, durability) lands with the
  execution issues (#7, #13, #15).
  """

  @type runner_ref :: reference()
  @type artifact :: map()
  @type target :: map()

  @callback start(
              Vigil.Plugin.integration_id(),
              artifact(),
              targets :: [target()],
              opts :: map()
            ) :: {:ok, runner_ref()} | {:error, term()}

  @callback abort(runner_ref()) :: :ok
end
