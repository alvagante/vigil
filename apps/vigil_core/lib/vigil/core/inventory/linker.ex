defmodule Vigil.Core.Inventory.Linker do
  @moduledoc """
  Supervised GenServer that owns the multi-attribute inverted index and runs the
  node-linking algorithm (design §5.2, ADR-0003).

  ## Algorithm (per observation)

  1. Walk the attribute cascade: certname → fqdn → hostname → ip
     IP is skipped unless the observation's confidence map marks it `:canonical`
     or `:strong` (INV-104: IP-only matching is disabled by default).
  2. Point-lookup each attribute in the ETS index.
  3. Three cases:
     (a) No match — create new canonical node + index all attrs.
     (b) One match — upsert node_sources, add any new attr claims.
     (c) Multiple matches — check manual_links; else write link_conflicts row.

  ## Serialization

  All index writes go through this GenServer's mailbox. ETS tables are
  `:protected` so any process reads without a GenServer round-trip.
  """

  use GenServer

  alias Vigil.Core.Inventory.Linker.Index
  alias Vigil.Core.Inventory.Observation
  alias Vigil.Core.Nodes
  alias Vigil.Repo

  # Cascade order (INV-104). IP is only included if confidence says so.
  @cascade [:certname, :fqdn, :hostname, :ip]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API ---

  @doc "Decommission a node: release ETS claims, update lifecycle in DB."
  @spec decommission(binary(), binary(), String.t() | nil) :: :ok | {:error, any()}
  def decommission(node_id, user_id, reason \\ nil) do
    GenServer.call(__MODULE__, {:decommission, node_id, user_id, reason})
  end

  @doc "Test helper: flush all ETS index tables via the owner process."
  @spec flush_index() :: :ok
  def flush_index do
    GenServer.call(__MODULE__, :flush_index)
  end

  @doc "Synchronously process one observation (used in tests and maintenance)."
  @spec link_observation(Observation.t()) :: {:ok, binary()} | {:error, :conflict} | {:error, any()}
  def link_observation(%Observation{} = obs) do
    GenServer.call(__MODULE__, {:link_observation, obs})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    Index.init()

    try do
      rebuild_from_db()
    rescue
      _ -> :ok
    end

    Phoenix.PubSub.subscribe(Vigil.PubSub, "inventory:cache_refreshed")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:integration_cache_refreshed, integration_id, observations}, state) do
    resolved_node_ids =
      observations
      |> Enum.map(fn obs -> {obs, do_link_one(obs)} end)
      |> Enum.flat_map(fn
        {_obs, {:ok, node_id}} -> [node_id]
        {_obs, _} -> []
      end)
      |> MapSet.new()

    detect_unreported(integration_id, resolved_node_ids)
    {:noreply, state}
  end

  @impl true
  def handle_call({:decommission, node_id, user_id, reason}, _from, state) do
    Index.release_claims(node_id)

    result =
      try do
        Nodes.decommission(node_id, user_id, reason)
      rescue
        e -> {:error, {:db_error, Exception.message(e)}}
      end

    {:reply, result, state}
  end

  def handle_call(:flush_index, _from, state) do
    for t <- [:linker_certname, :linker_fqdn, :linker_hostname, :linker_ip] do
      :ets.delete_all_objects(t)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:link_observation, obs}, _from, state) do
    result =
      try do
        do_link_one(obs)
      rescue
        e -> {:error, {:db_error, Exception.message(e)}}
      end

    {:reply, result, state}
  end

  # --- Startup rebuild ---

  defp rebuild_from_db do
    Nodes.stream_active_and_unreported()
    |> Enum.each(fn %{id: node_id, identity_attrs: attrs} ->
      for {attr, value} <- attrs,
          attr_atom = maybe_to_atom(attr),
          attr_atom in @cascade,
          is_binary(value) and value != "" do
        Index.put(attr_atom, value, node_id)
      end
    end)
  end

  # --- Core algorithm ---

  defp do_link_one(%Observation{} = obs) do
    attrs_to_check = cascade_attrs(obs)

    hits =
      attrs_to_check
      |> Enum.map(fn {attr, value} -> Index.lookup(attr, value) end)
      |> Enum.flat_map(fn
        {:ok, node_id} -> [node_id]
        :miss -> []
      end)
      |> Enum.uniq()

    case hits do
      [] ->
        create_new_node(obs)

      [node_id] ->
        claim_new_attrs(obs, node_id)
        upsert_source(obs, node_id)
        {:ok, node_id}

      multiple_ids ->
        handle_conflict(obs, multiple_ids)
    end
  end

  # Case (a): no existing node — create one and index all attrs
  defp create_new_node(obs) do
    canonical_name = derive_canonical_name(obs)
    identity_attrs = build_identity_attrs(obs)

    case Nodes.insert(%{canonical_name: canonical_name, identity_attrs: identity_attrs}) do
      {:ok, node} ->
        for {attr, value} <- cascade_attrs(obs) do
          Index.put(attr, value, node.id)
        end

        upsert_source(obs, node.id)
        {:ok, node.id}

      {:error, %Ecto.Changeset{errors: [canonical_name: _]}} ->
        # Race: another process created the same canonical name — fetch and use it
        case Repo.get_by(Vigil.Core.Inventory.Node, [canonical_name: canonical_name]) do
          nil -> {:error, :insert_race}
          node -> claim_new_attrs(obs, node.id); upsert_source(obs, node.id); {:ok, node.id}
        end

      {:error, _} = err ->
        err
    end
  end

  # Case (b): one match — add new attr claims that aren't already indexed
  defp claim_new_attrs(obs, node_id) do
    for {attr, value} <- cascade_attrs(obs) do
      case Index.lookup(attr, value) do
        :miss -> Index.put(attr, value, node_id)
        {:ok, ^node_id} -> :already_claimed
        {:ok, _other} -> :conflict_attr
      end
    end
  end

  # Case (c): multiple candidates — check manual_links (#23), else write conflict row
  defp handle_conflict(obs, candidate_ids) do
    # manual_links application is wired in #23; until then always :no_override
    candidates = Enum.map(candidate_ids, fn id -> %{node_id: id} end)
    observation_map = %{
      plugin_id: obs.plugin_id,
      integration_id: obs.integration_id,
      source_identity: obs.source_identity
    }

    Nodes.insert_conflict(%{observation: observation_map, candidates: candidates})
    {:error, :conflict}
  end

  # --- Unreported detection (DM-1109) ---

  defp detect_unreported(integration_id, current_node_ids) do
    previous_ids = Nodes.ids_currently_attributed_to(integration_id)
    dropped_ids = MapSet.difference(previous_ids, current_node_ids)

    for node_id <- dropped_ids do
      case Nodes.remove_source(node_id, integration_id) do
        {:ok, %{remaining_sources: 0}} ->
          Nodes.transition_lifecycle(node_id, :unreported)

        {:ok, _} ->
          :ok
      end
    end
  end

  # --- Helpers ---

  # Cascade order per INV-104: certname → fqdn → hostname → ip (ip skipped unless enabled)
  defp cascade_attrs(%Observation{source_identity: si, confidence: conf}) do
    @cascade
    |> Enum.flat_map(fn attr ->
      case Map.get(si, attr) do
        nil -> []
        value ->
          if attr == :ip and ip_disabled?(conf) do
            []
          else
            [{attr, value}]
          end
      end
    end)
  end

  # IP is only followed if confidence is :canonical or :strong (not :unstable / missing)
  defp ip_disabled?(conf) do
    Map.get(conf, :ip) not in [:canonical, :strong]
  end

  defp upsert_source(obs, node_id) do
    Nodes.upsert_source(%{
      node_id: node_id,
      integration_id: obs.integration_id,
      plugin_id: obs.plugin_id,
      source_identity: obs.source_identity,
      groups: obs.groups,
      last_seen_at: obs.last_seen
    })
  end

  defp derive_canonical_name(%Observation{source_identity: si, plugin_id: pid}) do
    # Priority: certname > fqdn > hostname > ip > plugin_id (fallback)
    si[:certname] || si[:fqdn] || si[:hostname] || si[:ip] ||
      "#{pid}-#{:erlang.unique_integer([:positive])}"
  end

  defp build_identity_attrs(%Observation{source_identity: si}) do
    si
    |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
    |> Map.new()
  end

  defp maybe_to_atom(k) when is_atom(k), do: k

  defp maybe_to_atom(k) when is_binary(k) do
    case k do
      "certname" -> :certname
      "fqdn" -> :fqdn
      "hostname" -> :hostname
      "ip" -> :ip
      _ -> nil
    end
  end
end
