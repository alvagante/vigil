defmodule Vigil.Integrations.Puppet.Puppetserver.Client do
  @moduledoc """
  Functional interface for Puppetserver API operations: environment list,
  environment cache flush, and code deployment (webhook / Code Manager / remote-exec).

  Routes HTTP calls through the configured transport module. Config is read from
  `ConfigServer` on every call. Puppetserver failures do NOT feed the circuit
  breaker (which is keyed to PuppetDB health) — the AC in #18 requires this
  isolation explicitly.
  """

  alias Vigil.Integrations.Puppet.{ConfigServer, Environment}
  alias Vigil.Integrations.Puppet.Puppetserver.FinchHTTP
  alias Vigil.Plugin.Error

  @doc "Fetch the list of known environments from Puppetserver (PUP-501)."
  @spec list_environments(Vigil.Plugin.integration_id()) ::
          {:ok, [Environment.t()]} | {:error, term()}
  def list_environments(integration_id) do
    with {:ok, config} <- ConfigServer.get_config(integration_id),
         {:ok, base_url} <- pss_url(config),
         http_module <- http_module(config),
         opts <- build_opts(config) do
      url = "#{base_url}/puppet/v3/environments"

      case http_module.request(:get, url, nil, opts) do
        {:ok, body} -> parse_environments(body)
        {:error, reason} -> {:error, pss_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, config_not_found_error()}
      {:error, :no_puppetserver_url} -> {:error, no_pss_url_error()}
    end
  end

  @doc "Delete the Puppetserver environment cache (PUP-502). Pass nil to flush all environments."
  @spec flush_environment_cache(Vigil.Plugin.integration_id(), String.t() | nil) ::
          {:ok, :flushed} | {:error, term()}
  def flush_environment_cache(integration_id, environment \\ nil) do
    with {:ok, config} <- ConfigServer.get_config(integration_id),
         {:ok, base_url} <- pss_url(config),
         http_module <- http_module(config),
         opts <- build_opts(config) do
      url = flush_url(base_url, environment)

      case http_module.request(:delete, url, nil, opts) do
        {:ok, _} -> {:ok, :flushed}
        {:error, reason} -> {:error, pss_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, config_not_found_error()}
      {:error, :no_puppetserver_url} -> {:error, no_pss_url_error()}
    end
  end

  @doc "POST to the configured r10k webhook endpoint (PUP-506)."
  @spec webhook_deploy(Vigil.Plugin.integration_id(), :all | {:single, String.t()}) ::
          {:ok, term()} | {:error, term()}
  def webhook_deploy(integration_id, scope) do
    with {:ok, config} <- ConfigServer.get_config(integration_id),
         {:ok, url} <- deploy_url(config),
         http_module <- http_module(config),
         opts <- build_opts(config) do
      body = build_webhook_body(scope)

      case http_module.request(:post, url, body, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, pss_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, config_not_found_error()}
      {:error, :no_deploy_url} -> {:error, no_deploy_url_error()}
    end
  end

  @doc "POST to the Code Manager API endpoint (PUP-505)."
  @spec code_manager_deploy(Vigil.Plugin.integration_id(), :all | {:single, String.t()}) ::
          {:ok, term()} | {:error, term()}
  def code_manager_deploy(integration_id, scope) do
    with {:ok, config} <- ConfigServer.get_config(integration_id),
         {:ok, url} <- deploy_url(config),
         http_module <- http_module(config),
         token <- Map.get(config, "code_deploy.bearer_token"),
         opts <- build_opts(config, bearer_token: token) do
      body = build_code_manager_body(scope)

      case http_module.request(:post, url, body, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, pss_error(reason)}
      end
    else
      {:error, :not_found} -> {:error, config_not_found_error()}
      {:error, :no_deploy_url} -> {:error, no_deploy_url_error()}
    end
  end

  ## Private helpers

  defp http_module(config),
    do: Map.get(config, "puppetserver.http_module", FinchHTTP)

  defp build_opts(config, extra \\ []) do
    base =
      case Map.get(config, "puppetserver.http_module") do
        nil -> [finch_name: FinchHTTP.pool_name(config["integration_id"] || "default")]
        _ -> Map.get(config, "puppetserver.http_opts", [])
      end

    base ++ extra
  end

  defp pss_url(config) do
    case Map.get(config, "puppetserver.url") do
      nil -> {:error, :no_puppetserver_url}
      url -> {:ok, url}
    end
  end

  defp deploy_url(config) do
    case Map.get(config, "code_deploy.url") do
      nil -> {:error, :no_deploy_url}
      url -> {:ok, url}
    end
  end

  defp flush_url(base_url, nil), do: "#{base_url}/puppet-admin-api/v1/environment-cache"
  defp flush_url(base_url, env), do: "#{base_url}/puppet-admin-api/v1/environment-cache?environment=#{env}"

  defp parse_environments(%{"environments" => envs}) when is_map(envs) do
    {:ok, Enum.map(envs, fn {name, _settings} -> %Environment{name: name} end)}
  end

  defp parse_environments(_), do: {:error, :invalid_response}

  defp build_webhook_body(:all), do: %{}
  defp build_webhook_body({:single, env}), do: %{environment: env}

  defp build_code_manager_body(:all), do: %{"all" => true}
  defp build_code_manager_body({:single, env}), do: %{"environments" => [%{"name" => env}]}

  defp pss_error(reason) do
    %Error{
      category: :transient_external,
      message: "Puppetserver request failed: #{inspect(reason)}",
      detail: %{reason: reason},
      retriable?: true,
      upstream_fault?: true
    }
  end

  defp config_not_found_error do
    %Error{
      category: :configuration,
      message: "no running Puppet integration found",
      retriable?: false
    }
  end

  defp no_pss_url_error do
    %Error{
      category: :config_error,
      message: "puppetserver.url is not configured",
      retriable?: false
    }
  end

  defp no_deploy_url_error do
    %Error{
      category: :config_error,
      message: "code_deploy.url is not configured",
      retriable?: false
    }
  end
end
