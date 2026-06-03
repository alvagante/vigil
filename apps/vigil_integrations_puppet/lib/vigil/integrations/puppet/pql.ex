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

  defp environment_clause(nil), do: nil

  defp environment_clause(env) do
    ~s|catalog_environment = "#{escape_string(env)}"|
  end

  defp status_clause(nil), do: nil

  defp status_clause(status) do
    ~s|latest_report_status = "#{escape_string(to_string(status))}"|
  end
end
