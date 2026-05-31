defmodule VigilWeb.Live.HealthLive do
  @moduledoc """
  Integration health dashboard — ROAD-103 / issue #5.
  Route: /health

  Subscribes to `integration_health:<id>` for each configured integration and
  updates status in real-time without polling. The initial render uses the
  `health` column from the DB (last known state) so the page loads fast; live
  PubSub messages then override it as probes arrive.
  """

  use VigilWeb, :live_view

  alias Vigil.Core.IntegrationConfig

  @impl true
  def mount(_params, _session, socket) do
    integrations = IntegrationConfig.list_all()

    if connected?(socket) do
      Enum.each(integrations, fn i ->
        Phoenix.PubSub.subscribe(Vigil.PubSub, "integration_health:#{i.id}")
      end)
    end

    health_map =
      Map.new(integrations, fn i ->
        initial =
          case i.health do
            %{"status" => s} -> String.to_existing_atom(s)
            _ -> :starting
          end

        {i.id, %{status: initial, capabilities: [], diagnostic: %{}, checked_at: nil}}
      end)

    {:ok,
     socket
     |> assign(:page_title, "Health")
     |> assign(:integrations, integrations)
     |> assign(:health_map, health_map)}
  end

  @impl true
  def handle_info({:health, id, status, capabilities, diagnostic}, socket) do
    health_map =
      Map.update(socket.assigns.health_map, id, initial_health(status), fn entry ->
        %{entry | status: status, capabilities: capabilities, diagnostic: diagnostic, checked_at: DateTime.utc_now()}
      end)

    {:noreply, assign(socket, :health_map, health_map)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp initial_health(status) do
    %{status: status, capabilities: [], diagnostic: %{}, checked_at: DateTime.utc_now()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <Layouts.flash_group flash={@flash} />
      <h1 class="text-2xl font-bold mb-6">Integration Health</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <%= for integration <- @integrations do %>
          <% health = Map.get(@health_map, integration.id, %{status: :starting}) %>
          <div class={"card bg-base-200 shadow #{status_card_class(health.status)}"}>
            <div class="card-body">
              <h2 class="card-title">
                <%= integration.name %>
                <div class={"badge #{status_badge_class(health.status)}"}><%= health.status %></div>
              </h2>
              <p class="text-sm text-base-content/60">Plugin: <%= integration.plugin_id %></p>
              <%= if health[:checked_at] do %>
                <p class="text-xs text-base-content/40">
                  Last check: <%= Calendar.strftime(health.checked_at, "%H:%M:%S UTC") %>
                </p>
              <% end %>
              <%= if integration.enabled == false do %>
                <div class="badge badge-ghost">disabled</div>
              <% end %>
            </div>
          </div>
        <% end %>
        <%= if @integrations == [] do %>
          <div class="col-span-full text-center text-base-content/50 py-12">
            No integrations configured. Visit
            <a href="/settings/integrations" class="link">Settings → Integrations</a>
            to add one.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp status_badge_class(:healthy), do: "badge-success"
  defp status_badge_class(:degraded), do: "badge-warning"
  defp status_badge_class(:unhealthy), do: "badge-error"
  defp status_badge_class(:starting), do: "badge-info"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_card_class(:unhealthy), do: "border-2 border-error"
  defp status_card_class(:degraded), do: "border-2 border-warning"
  defp status_card_class(_), do: ""
end
