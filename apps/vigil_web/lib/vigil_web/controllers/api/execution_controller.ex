defmodule VigilWeb.API.ExecutionController do
  use VigilWeb, :controller

  alias Vigil.Plugin.Executions, as: PluginExecutions

  def create(conn, params) do
    with {:ok, integration_id} <- require_param(params, "integration_id"),
         {:ok, submit_params} <- build_submit_params(params, integration_id) do
      principal = conn.assigns.current_user

      case PluginExecutions.submit(principal, submit_params) do
        {:ok, group_id} ->
          json(conn, %{group_id: group_id})

        {:error, :all_denied} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "execution denied by role policy"})

        {:error, %{message: msg}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: msg})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: msg})
    end
  end

  defp build_submit_params(%{"kind" => kind} = params, integration_id)
       when kind in ["task", "plan"] do
    with {:ok, name} <- require_param(params, "name"),
         {:ok, plugin_id} <- lookup_plugin_id(integration_id) do
      artifact_kind = String.to_existing_atom(kind)
      params_value = Map.get(params, "params", %{})
      node_ids = if kind == "plan", do: ["__plan__"], else: Map.get(params, "node_ids", [])

      {:ok,
       %{
         integration_id: integration_id,
         artifact: %{kind: artifact_kind, name: name, params: params_value},
         targets: %{node_ids: node_ids},
         permission_action: "#{plugin_id}:#{kind}:execute"
       }}
    end
  end

  defp build_submit_params(params, integration_id) do
    with {:ok, command} <- require_param(params, "command"),
         {:ok, node_ids} <- require_list(params, "node_ids"),
         {:ok, plugin_id} <- lookup_plugin_id(integration_id) do
      {:ok,
       %{
         integration_id: integration_id,
         artifact: %{kind: :command, text: command},
         targets: %{node_ids: node_ids},
         permission_action: "#{plugin_id}:command:execute"
       }}
    end
  end

  defp lookup_plugin_id(integration_id) do
    case Vigil.Repo.get(Vigil.Core.Integration, integration_id) do
      nil -> {:error, "integration #{inspect(integration_id)} not found"}
      integration -> {:ok, integration.plugin_id}
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "#{key} is required"}
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp require_list(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "#{key} is required"}
      [] -> {:error, "#{key} must not be empty"}
      list when is_list(list) -> {:ok, list}
      _ -> {:error, "#{key} must be a list"}
    end
  end
end
