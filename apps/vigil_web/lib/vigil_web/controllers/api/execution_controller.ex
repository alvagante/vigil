defmodule VigilWeb.API.ExecutionController do
  use VigilWeb, :controller

  alias Vigil.Plugin.Executions, as: PluginExecutions

  def create(conn, params) do
    with {:ok, integration_id} <- require_param(params, "integration_id"),
         {:ok, command} <- require_param(params, "command"),
         {:ok, node_ids} <- require_list(params, "node_ids") do
      principal = conn.assigns.current_user

      submit_params = %{
        integration_id: integration_id,
        artifact: %{kind: :command, text: command},
        targets: %{node_ids: node_ids},
        permission_action: "ssh:command:execute"
      }

      case PluginExecutions.submit(principal, submit_params) do
        {:ok, group_id} ->
          json(conn, %{group_id: group_id})

        {:error, :all_denied} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "command denied by role policy"})

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
