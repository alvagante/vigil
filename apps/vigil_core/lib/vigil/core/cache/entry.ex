defmodule Vigil.Core.Cache.Entry do
  @moduledoc false

  @type t :: %__MODULE__{
          data: term(),
          source_attribution: map(),
          stored_at: DateTime.t(),
          expires_at: DateTime.t(),
          source_health_at_store: :healthy | :degraded,
          size_bytes: non_neg_integer()
        }

  defstruct [
    :data,
    :source_attribution,
    :stored_at,
    :expires_at,
    source_health_at_store: :healthy,
    size_bytes: 0
  ]

  @spec new(term(), map(), non_neg_integer()) :: t()
  def new(data, source_attribution, ttl_ms) do
    now = DateTime.utc_now()

    %__MODULE__{
      data: data,
      source_attribution: source_attribution,
      stored_at: now,
      expires_at: DateTime.add(now, ttl_ms, :millisecond),
      source_health_at_store: :healthy,
      size_bytes: :erlang.external_size(data)
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}), do: DateTime.compare(DateTime.utc_now(), exp) != :lt
end
