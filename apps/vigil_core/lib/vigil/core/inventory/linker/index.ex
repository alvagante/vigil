defmodule Vigil.Core.Inventory.Linker.Index do
  @moduledoc """
  ETS-backed multi-attribute inverted index for O(1) node_id lookups (design §5.2.2, ADR-0003).

  Four named `:set` tables owned by the Linker process; any process can read directly.
  Record shape: {normalized_value, node_id} — the second element is used by
  `:ets.match_delete(t, {:_, node_id})` for O(table_size) decommission claim release.
  """

  @tables [:linker_certname, :linker_fqdn, :linker_hostname, :linker_ip]

  @spec init() :: [:ok]
  def init do
    for t <- @tables do
      if :ets.whereis(t) == :undefined do
        :ets.new(t, [:set, :named_table, :protected, {:read_concurrency, true}])
      end

      :ok
    end
  end

  @doc "Insert `attr → node_id` into the index for `attr`."
  @spec put(atom(), String.t(), binary()) :: true
  def put(:certname, value, node_id), do: :ets.insert(:linker_certname, {normalize(:certname, value), node_id})
  def put(:fqdn, value, node_id), do: :ets.insert(:linker_fqdn, {normalize(:fqdn, value), node_id})
  def put(:hostname, value, node_id), do: :ets.insert(:linker_hostname, {normalize(:hostname, value), node_id})
  def put(:ip, value, node_id), do: :ets.insert(:linker_ip, {normalize(:ip, value), node_id})

  @doc "Point-lookup: return `{:ok, node_id}` or `:miss`."
  @spec lookup(atom(), String.t()) :: {:ok, binary()} | :miss
  def lookup(:certname, value), do: ets_get(:linker_certname, normalize(:certname, value))
  def lookup(:fqdn, value), do: ets_get(:linker_fqdn, normalize(:fqdn, value))
  def lookup(:hostname, value), do: ets_get(:linker_hostname, normalize(:hostname, value))
  def lookup(:ip, value), do: ets_get(:linker_ip, normalize(:ip, value))

  @doc "Remove all index entries attributed to `node_id` across all tables."
  @spec release_claims(binary()) :: :ok
  def release_claims(node_id) do
    for t <- @tables do
      :ets.match_delete(t, {:_, node_id})
    end

    :ok
  end

  @doc "Normalize an attribute value for storage and lookup."
  @spec normalize(atom(), String.t()) :: String.t()
  def normalize(:certname, v), do: String.downcase(v)
  def normalize(:fqdn, v), do: v |> String.downcase() |> String.trim_trailing(".")
  def normalize(:hostname, v), do: String.downcase(v)
  def normalize(:ip, v), do: canonicalize_ip(v)

  # --- private ---

  defp ets_get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, node_id}] -> {:ok, node_id}
      [] -> :miss
    end
  end

  defp canonicalize_ip(v) do
    v_charlist = String.to_charlist(v)

    case :inet.parse_address(v_charlist) do
      {:ok, addr} -> :inet.ntoa(addr) |> to_string()
      {:error, _} -> v
    end
  end
end
