defmodule Vigil.Integrations.Puppet.PQL do
  @moduledoc """
  Safe PQL (Puppet Query Language) builder.

  String interpolation into PQL is forbidden — it is an injection vector
  equivalent to SQL injection (design §11.2.1). All user-supplied values
  are routed through `escape_string/1` before inclusion in a query.
  """

  @doc """
  Builds a PQL nodes query for inventory listing with optional filters.

  Accepted filter keys: `:environment`, `:status`. All values are escaped.
  """
  @spec nodes_query(map() | nil) :: String.t()
  def nodes_query(nil), do: nodes_query(%{})

  def nodes_query(filter) when is_map(filter) do
    clauses = build_clauses(filter)
    body = if clauses == [], do: "", else: " { #{Enum.join(clauses, " and ")} }"
    "nodes[certname, deactivated, expired, latest_report_status]#{body}"
  end

  @doc "Builds a PQL facts query for a single certname."
  @spec facts_query(String.t()) :: String.t()
  def facts_query(certname) do
    ~s|facts[certname, name, value] { certname = "#{escape_string(certname)}" }|
  end

  @doc "Builds the minimal probe query used by health checks."
  @spec probe_query() :: String.t()
  def probe_query do
    "nodes[certname] { order by certname limit 1 }"
  end

  @doc """
  Builds a PQL reports query with optional certname filter.

  Accepted filter keys: `:certname`, `:limit`. All values are escaped.
  """
  @spec reports_query(map() | nil) :: String.t()
  def reports_query(nil), do: reports_query(%{})

  def reports_query(filter) when is_map(filter) do
    fields =
      "certname, environment, status, start_time, end_time, run_duration, " <>
        "num_changes, num_failures, num_corrective_changes, num_skips, num_noops, " <>
        "noop, catalog_uuid, code_id, hash"

    clauses =
      [certname_clause(Map.get(filter, :certname) || Map.get(filter, "certname"))]
      |> Enum.reject(&is_nil/1)

    body = if clauses == [], do: "", else: " { #{Enum.join(clauses, " and ")} }"
    limit = Map.get(filter, :limit) || Map.get(filter, "limit")
    suffix = if limit, do: " limit #{trunc(limit)}", else: ""

    "reports[#{fields}]#{body}#{suffix}"
  end

  @doc """
  Builds a PQL events query for a certname and time range.

  Noop events are excluded server-side via `status in ["success", "failure"]`
  (PUP-604). The certname and time values are escaped.
  """
  @spec events_query(String.t(), map()) :: String.t()
  def events_query(certname, time_range) when is_binary(certname) and is_map(time_range) do
    fields =
      "certname, timestamp, resource_type, resource_title, status, " <>
        "old_value, new_value, message, file, line, containment_path, report"

    from = escape_string(to_string(time_range[:from] || time_range["from"] || ""))
    to = escape_string(to_string(time_range[:to] || time_range["to"] || ""))

    ~s|events[#{fields}] { | <>
      ~s|certname = "#{escape_string(certname)}" | <>
      ~s|and timestamp >= "#{from}" | <>
      ~s|and timestamp <= "#{to}" | <>
      ~s|and status in ["success", "failure"] }|
  end

  @doc "Builds a PQL catalogs query for a single certname (PUP-401)."
  @spec catalog_query(String.t()) :: String.t()
  def catalog_query(certname) when is_binary(certname) do
    ~s|catalogs[certname, environment, version, resources, edges] { certname = "#{escape_string(certname)}" }|
  end

  @doc """
  Escapes a string value for safe inclusion in a PQL double-quoted string.
  Escapes backslash and double-quote characters.
  """
  @spec escape_string(String.t()) :: String.t()
  def escape_string(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp build_clauses(filter) do
    [
      environment_clause(Map.get(filter, :environment) || Map.get(filter, "environment")),
      status_clause(Map.get(filter, :status) || Map.get(filter, "status"))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp certname_clause(nil), do: nil

  defp certname_clause(certname) do
    ~s|certname = "#{escape_string(certname)}"|
  end

  defp environment_clause(nil), do: nil

  defp environment_clause(env) do
    ~s|catalog_environment = "#{escape_string(env)}"|
  end

  defp status_clause(nil), do: nil

  defp status_clause(status) do
    ~s|latest_report_status = "#{escape_string(to_string(status))}"|
  end
end
