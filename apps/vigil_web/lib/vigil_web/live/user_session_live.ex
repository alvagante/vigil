defmodule VigilWeb.Live.UserSessionLive do
  use VigilWeb, :live_view

  alias VigilWeb.Layouts

  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] do
      {:ok, redirect(socket, to: ~p"/")}
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-sm mt-16">
        <h1 class="text-2xl font-bold mb-6">Log in</h1>
        <.form for={to_form(%{})} action={~p"/users/log_in"} method="post">
          <div class="mb-4">
            <label for="username">Username</label>
            <input type="text" id="username" name="username" required />
          </div>
          <div class="mb-4">
            <label for="password">Password</label>
            <input type="password" id="password" name="password" required />
          </div>
          <button type="submit">Log in</button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
