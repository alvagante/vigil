defmodule Vigil.Core.Inventory.Observation do
  @moduledoc """
  A node observation as produced by one integration's inventory refresh (design §5.2.1).

  `source_identity` carries the raw identity map from the plugin, e.g.:
    %{certname: "web-01.prod", fqdn: "web-01.prod.example.com"}
  or for SSH:
    %{hostname: "web-01", ip: "10.0.0.1"}

  `confidence` is a per-attribute map:  :canonical | :strong | :unstable
  Per INV-104, IP matching is disabled by default — the confidence map
  drives which attributes the Linker will actually cascade over.

  The `Linker` is the only consumer of this struct; integrations produce
  Plugin.Node values and the caller (Cache.Server broadcast or test harness)
  is responsible for converting them to Observations before broadcasting.
  """

  @enforce_keys [:plugin_id, :integration_id, :source_identity]

  defstruct [
    :plugin_id,
    :integration_id,
    :source_identity,
    confidence: %{},
    groups: [],
    last_seen: nil
  ]

  @type attribute :: :certname | :fqdn | :hostname | :ip
  @type confidence_level :: :canonical | :strong | :unstable
  @type source_identity :: %{optional(attribute()) => String.t()}

  @type t :: %__MODULE__{
          plugin_id: String.t(),
          integration_id: String.t(),
          source_identity: source_identity(),
          confidence: %{optional(attribute()) => confidence_level()},
          groups: [String.t()],
          last_seen: DateTime.t() | nil
        }

  @doc """
  Build an Observation from a Plugin.Node's name and attributes map.

  Guesses confidence based on the attribute type:
  - :certname → :canonical (Puppet-style)
  - :fqdn → :strong
  - :hostname → :strong
  - :ip → :unstable

  Pass `confidence` explicitly to override.
  """
  @spec from_plugin_node(String.t(), String.t(), map(), keyword()) :: t()
  def from_plugin_node(plugin_id, integration_id, attrs, opts \\ []) do
    keys = [:certname, :fqdn, :hostname, :ip]

    source_identity =
      attrs
      |> Map.take(keys)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    default_confidence =
      source_identity
      |> Map.keys()
      |> Enum.map(fn
        :certname -> {:certname, :canonical}
        :fqdn -> {:fqdn, :strong}
        :hostname -> {:hostname, :strong}
        :ip -> {:ip, :unstable}
      end)
      |> Map.new()

    %__MODULE__{
      plugin_id: plugin_id,
      integration_id: integration_id,
      source_identity: source_identity,
      confidence: Keyword.get(opts, :confidence, default_confidence),
      groups: Keyword.get(opts, :groups, []),
      last_seen: Keyword.get(opts, :last_seen, DateTime.utc_now())
    }
  end
end
