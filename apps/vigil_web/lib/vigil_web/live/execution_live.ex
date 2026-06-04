defmodule VigilWeb.Live.ExecutionLive do
  @moduledoc """
  Execution history list (`/executions`) and per-group streaming view
  (`/executions/:group_id`) — issue #7.

  List view: shows all execution groups ordered by submission time, filterable
  by node_id and outcome query params.

  Detail view: loads the group's executions, subscribes to each target's
  `execution_stream:<execution_id>` PubSub topic, and appends chunks in
  real-time.
  """

  use VigilWeb, :live_view

  alias Vigil.Core.{Executions}
  alias Vigil.Plugin.Executions, as: PluginExecutions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:group_id, nil)
     |> assign(:group, nil)
     |> assign(:groups, [])
     |> assign(:exec_outputs, %{})
     |> assign(:filters, %{})
     |> assign(:page_title, "Executions")}
  end

  @impl true
  def handle_params(%{"group_id" => group_id}, _uri, socket) do
    groups = Executions.history()
    group = Enum.find(groups, &(&1.id == group_id))

    if connected?(socket) && group do
      Enum.each(group.executions, fn exec ->
        Phoenix.PubSub.subscribe(Vigil.PubSub, "execution_stream:#{exec.id}")
      end)
    end

    streams =
      if group do
        Map.new(group.executions, fn exec -> {exec.id, {exec, []}} end)
      else
        %{}
      end

    {:noreply,
     socket
     |> assign(:group_id, group_id)
     |> assign(:group, group)
     |> assign(:groups, groups)
     |> assign(:exec_outputs, streams)
     |> assign(:page_title, "Execution")}
  end

  def handle_params(params, _uri, socket) do
    filters =
      %{}
      |> maybe_put(:node_id, params["node_id"])
      |> maybe_put(:outcome, params["outcome"])

    {:noreply,
     socket
     |> assign(:groups, Executions.history(filters))
     |> assign(:group_id, nil)
     |> assign(:group, nil)
     |> assign(:filters, filters)}
  end

  @impl true
  def handle_info({:chunk, execution_id, data}, socket) do
    exec_outputs =
      Map.update(socket.assigns.exec_outputs, execution_id, nil, fn
        nil -> nil
        {exec, chunks} -> {exec, chunks ++ [data]}
      end)

    {:noreply, assign(socket, :exec_outputs, exec_outputs)}
  end

  def handle_info({:ended, _execution_id, _outcome}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("rerun_group", _params, socket) do
    principal = %{id: "anon"}
    group_id = socket.assigns.group_id

    case PluginExecutions.rerun_group(group_id, principal) do
      {:ok, new_group_id} ->
        {:noreply, push_navigate(socket, to: ~p"/executions/#{new_group_id}")}

      {:error, reason} ->
        msg =
          if is_map(reason), do: Map.get(reason, :message, inspect(reason)), else: inspect(reason)

        {:noreply, put_flash(socket, :error, "Re-run failed: #{msg}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <Layouts.flash_group flash={@flash} />
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Executions</h1>
        <.link navigate={~p"/executions/new"} class="btn btn-primary btn-sm">
          Run Command
        </.link>
      </div>

      <%= if @group do %>
        <.group_detail group={@group} exec_outputs={@exec_outputs} />
      <% else %>
        <.history_list groups={@groups} />
      <% end %>
    </div>
    """
  end

  defp group_detail(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <.link navigate={~p"/executions"} class="link link-neutral text-sm">
          &larr; All executions
        </.link>
      </div>
      <div class="card bg-base-200 p-4 mb-4">
        <div class="flex justify-between items-start">
          <div>
            <div class="font-mono text-sm">
              <span class="text-base-content/60">Command:</span>
              {artifact_text(@group.artifact)}
            </div>
            <div class="text-xs text-base-content/50 mt-1">
              Submitted {DateTime.to_string(@group.submitted_at)} &middot; {@group.dispatched_count} target(s)
            </div>
          </div>
          <button
            id="rerun-group-btn"
            phx-click="rerun_group"
            class="btn btn-sm btn-outline"
          >
            Re-run
          </button>
        </div>
      </div>

      <div :for={{exec, chunks} <- Map.values(@exec_outputs)} class="mb-4">
        <div class="font-semibold text-sm mb-1">{exec.node_id}</div>
        <pre
          class="bg-base-300 rounded p-3 text-xs font-mono overflow-x-auto whitespace-pre-wrap"
          id={"stream-#{exec.id}"}
        >
          <span :for={chunk <- chunks}>{chunk}</span>
          <span :if={chunks == [] && exec.outcome == "running"} class="text-base-content/40">
            Waiting for output…
          </span>
          <span :if={exec.transcript} class="text-base-content/60">{exec.transcript}</span>
        </pre>
      </div>
    </div>
    """
  end

  defp history_list(assigns) do
    ~H"""
    <div :if={@groups == []} class="text-center text-base-content/50 mt-16">
      No executions yet.
      <.link navigate={~p"/executions/new"} class="link link-primary">Run a command</.link>
      to get started.
    </div>

    <table :if={@groups != []} class="table table-zebra w-full">
      <thead>
        <tr>
          <th>Command</th>
          <th>Integration</th>
          <th>Targets</th>
          <th>Submitted</th>
          <th>Outcome</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={group <- @groups} id={"group-#{group.id}"}>
          <td>
            <.link navigate={~p"/executions/#{group.id}"} class="link link-primary font-mono text-sm">
              {artifact_text(group.artifact)}
            </.link>
          </td>
          <td class="text-sm text-base-content/70">{group.integration_id}</td>
          <td class="text-sm">{group.dispatched_count}</td>
          <td class="text-xs text-base-content/50">{DateTime.to_string(group.submitted_at)}</td>
          <td><.outcome_badge executions={group.executions} /></td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp outcome_badge(assigns) do
    outcomes = Enum.map(assigns.executions, & &1.outcome) |> Enum.uniq()

    assigns = assign(assigns, :outcomes, outcomes)

    ~H"""
    <span :for={o <- @outcomes} class={"badge #{outcome_class(o)} badge-sm"}>{o}</span>
    """
  end

  defp outcome_class("ok"), do: "badge-success"
  defp outcome_class("failed"), do: "badge-error"
  defp outcome_class("timed_out"), do: "badge-warning"
  defp outcome_class("running"), do: "badge-info"
  defp outcome_class(_), do: "badge-ghost"

  defp artifact_text(%{"text" => t}), do: t
  defp artifact_text(%{text: t}), do: t
  defp artifact_text(_), do: "(unknown)"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
