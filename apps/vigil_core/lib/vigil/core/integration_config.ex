defmodule Vigil.Core.IntegrationConfig do
  @moduledoc """
  Context for integration lifecycle management (design §2.4, §3.2.2).

  Owns writes to the `integrations` table and publishes PubSub events that
  drive `Vigil.Integrations.Manager` to spawn or terminate integration subtrees.
  Config validation against the plugin's declared schema happens in the caller
  (LiveView or Manager) — this context stores whatever it receives.

  Audit events (integration_enable, integration_disable, integration_config_update)
  are currently logged to the application logger with a "known limitation — #8
  replaces this with the real audit trail writer (ROAD-104)" note.
  """

  import Ecto.Query
  alias Vigil.{Repo, PubSub}
  alias Vigil.Core.Integration

  @pubsub_topic "integration_lifecycle"

  @doc "Return all integrations, ordered by name."
  def list_all do
    Repo.all(from(i in Integration, order_by: i.name))
  end

  @doc "Return all enabled integrations."
  def list_enabled do
    Repo.all(from(i in Integration, where: i.enabled == true, order_by: i.name))
  end

  @doc "Fetch an integration by id, raising if absent."
  def get!(id), do: Repo.get!(Integration, id)

  @doc "Create a new integration. Returns `{:ok, integration}` or `{:error, changeset}`."
  def create(attrs) do
    %Integration{}
    |> Integration.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing integration's config. Returns `{:ok, integration}` or `{:error, changeset}`."
  def update(%Integration{} = integration, attrs) do
    result =
      integration
      |> Integration.changeset(attrs)
      |> Repo.update()

    with {:ok, updated} <- result do
      audit(:integration_config_update, updated.id)

      Phoenix.PubSub.broadcast(
        PubSub,
        @pubsub_topic,
        {:integration_config_updated, updated.id, updated.config}
      )

      {:ok, updated}
    end
  end

  @doc "Enable an integration — persists the change and fires a PubSub event."
  def enable(id) do
    integration = get!(id)

    result =
      integration
      |> Integration.enable_changeset()
      |> Repo.update()

    with {:ok, updated} <- result do
      audit(:integration_enable, id)
      Phoenix.PubSub.broadcast(PubSub, @pubsub_topic, {:integration_enabled, id})
      {:ok, updated}
    end
  end

  @doc "Disable an integration — persists the change and fires a PubSub event."
  def disable(id) do
    integration = get!(id)

    result =
      integration
      |> Integration.disable_changeset()
      |> Repo.update()

    with {:ok, updated} <- result do
      audit(:integration_disable, id)
      Phoenix.PubSub.broadcast(PubSub, @pubsub_topic, {:integration_disabled, id})
      {:ok, updated}
    end
  end

  @doc "Mirror the latest health state into the DB row (convenience for page renders)."
  def update_health(id, health_attrs) do
    integration = get!(id)

    integration
    |> Integration.health_changeset(health_attrs)
    |> Repo.update()
  end

  # Minimal audit log per acceptance criteria — ROAD-104 / #8 replaces this.
  defp audit(event, integration_id) do
    require Logger
    Logger.info("[audit] #{event} integration_id=#{integration_id}")
  end
end
