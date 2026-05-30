defmodule Vigil.Plugin.Error do
  @moduledoc """
  Structured error returned by capability calls (design §3.1.2). The dispatcher
  maps these to circuit-breaker transitions, UI messages, and log
  classifications (PRD ERR-401..403).
  """

  @type category ::
          :configuration
          | :authentication
          | :authorization_upstream
          | :transient_external
          | :persistent_external
          | :internal_plugin
          | :user_input

  @enforce_keys [:category, :message]
  defstruct category: :transient_external,
            message: "",
            detail: %{},
            retriable?: false,
            upstream_fault?: false,
            correlation_id: nil

  @type t :: %__MODULE__{
          category: category(),
          message: String.t(),
          detail: map(),
          retriable?: boolean(),
          upstream_fault?: boolean(),
          correlation_id: String.t() | nil
        }
end
