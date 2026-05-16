defmodule VigilWeb.DashboardLive do
  use VigilWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <h1 class="text-3xl font-semibold tracking-tight">Vigil</h1>

        <div class="rounded-box border border-base-300 bg-base-200 p-6 space-y-3">
          <p class="text-base">
            no integrations configured — start with one of: Puppet, Ansible, SSH, Bolt.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
