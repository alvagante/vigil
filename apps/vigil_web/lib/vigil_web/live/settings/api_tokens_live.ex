defmodule VigilWeb.Live.Settings.APITokensLive do
  use VigilWeb, :live_view

  alias Vigil.Core.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    tokens = Accounts.list_tokens(user)

    {:ok,
     socket
     |> assign(:page_title, "API Tokens")
     |> assign(:tokens, tokens)
     |> assign(:new_token_value, nil)}
  end

  @impl true
  def handle_event("mint", %{"token" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user

    case Accounts.mint_token(user, String.trim(name), []) do
      {:ok, token_value} ->
        tokens = Accounts.list_tokens(user)

        {:noreply,
         socket
         |> assign(:tokens, tokens)
         |> assign(:new_token_value, token_value)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create token.")}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => token_id}, socket) do
    case Accounts.revoke_token(token_id) do
      :ok ->
        tokens = Accounts.list_tokens(socket.assigns.current_user)
        {:noreply, assign(socket, :tokens, tokens)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4 max-w-3xl">
      <h1 class="text-2xl font-bold mb-6">API Tokens</h1>

      <p class="mb-4 text-sm text-base-content/70">
        Tokens authenticate API requests in place of a session.
        A token's value is shown only once — copy it before leaving this page.
      </p>

      <%= if @new_token_value do %>
        <div class="alert alert-success mb-6">
          <span>New token created. Copy it now — it will not be shown again.</span>
          <code class="font-mono break-all"><%= @new_token_value %></code>
        </div>
      <% end %>

      <form id="mint-token-form" phx-submit="mint" class="flex gap-2 mb-8">
        <input
          type="text"
          name="token[name]"
          placeholder="Token name (e.g., ci-pipeline)"
          class="input input-bordered flex-1"
          required
        />
        <button type="submit" class="btn btn-primary">Issue token</button>
      </form>

      <table class="table w-full">
        <thead>
          <tr>
            <th>Name</th>
            <th>Last used</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={token <- @tokens}>
            <td><%= token.name %></td>
            <td><%= format_last_used(token.last_used_at) %></td>
            <td>
              <button
                phx-click="revoke"
                phx-value-id={token.id}
                class="btn btn-xs btn-error"
                data-confirm="Revoke this token?"
              >
                Revoke
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <%= if @tokens == [] do %>
        <p class="text-center text-base-content/50 mt-8">No active tokens.</p>
      <% end %>
    </div>
    """
  end

  defp format_last_used(nil), do: "Never"
  defp format_last_used(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
