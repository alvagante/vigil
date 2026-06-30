defmodule Vigil.Integrations.Puppet.Hiera.Reader do
  @moduledoc false
  @compile {:no_warn_undefined, YamlElixir}

  alias Vigil.Integrations.Puppet.ConfigServer
  alias Vigil.Integrations.Puppet.Hiera.{Level, Resolution}
  alias Vigil.Plugin.Error

  def read_hierarchy(integration_id, environment) do
    with {:ok, repo_path, hiera_file} <- hiera_config(integration_id),
         path = hierarchy_path(repo_path, environment, hiera_file),
         {:ok, contents} <- read_file(path),
         {:ok, yaml} <- parse_yaml(contents) do
      {:ok, normalize_hierarchy(yaml)}
    end
  end

  def resolve_key(integration_id, environment, key, node_context, opts \\ []) do
    merge_strategy = opts[:merge] || :first

    with {:ok, repo_path, hiera_file} <- hiera_config(integration_id),
         path = hierarchy_path(repo_path, environment, hiera_file),
         {:ok, contents} <- read_file(path),
         {:ok, yaml} <- parse_yaml(contents),
         levels = normalize_hierarchy(yaml) do
      walk_hierarchy(levels, key, repo_path, environment, node_context, merge_strategy)
    end
  end

  ## Private

  defp hiera_config(integration_id) do
    case ConfigServer.get_config(integration_id) do
      {:ok, config} ->
        repo_path = config["control_repo.path"]
        hiera_file = config["hiera.config_file"] || "hiera.yaml"

        if is_nil(repo_path) or repo_path == "" do
          {:error,
           %Error{
             category: :config_error,
             message: "control_repo.path is not configured for this integration",
             retriable?: false
           }}
        else
          {:ok, repo_path, hiera_file}
        end

      {:error, :not_found} ->
        {:error,
         %Error{
           category: :config_error,
           message: "integration #{integration_id} not found",
           retriable?: false
         }}
    end
  end

  defp hierarchy_path(repo_path, environment, hiera_file) do
    Path.join([repo_path, "environments", environment, hiera_file])
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error,
         %Error{
           category: :not_found,
           message: "Hiera config not found: #{path}",
           retriable?: false
         }}

      {:error, reason} ->
        {:error,
         %Error{
           category: :config_error,
           message: "Failed to read #{path}: #{inspect(reason)}",
           retriable?: false
         }}
    end
  end

  defp parse_yaml(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, yaml} ->
        {:ok, yaml}

      {:error, reason} ->
        {:error,
         %Error{
           category: :parse_error,
           message: "Malformed YAML: #{inspect(reason)}",
           retriable?: false
         }}
    end
  end

  defp normalize_hierarchy(%{"hierarchy" => levels}) when is_list(levels) do
    Enum.map(levels, fn entry ->
      %Level{
        name: entry["name"] || "unnamed",
        data_source_path: entry["path"] || entry["paths"] || "",
        backend: :yaml,
        options: Map.drop(entry, ["name", "path", "paths"])
      }
    end)
  end

  defp normalize_hierarchy(_), do: []

  defp walk_hierarchy(levels, key, repo_path, environment, node_context, merge_strategy) do
    env_dir = Path.join([repo_path, "environments", environment])
    chain_entries = Enum.map(levels, &probe_level(&1, key, env_dir, node_context))

    resolution =
      case merge_strategy do
        :first -> resolve_first(chain_entries, key)
        :hash -> resolve_merge(chain_entries, key, :hash)
        :unique -> resolve_merge(chain_entries, key, :unique)
        :deep -> resolve_merge(chain_entries, key, :deep)
      end

    {:ok, resolution}
  end

  defp probe_level(%Level{data_source_path: pattern} = level, key, data_dir, node_context) do
    interpolated = interpolate(pattern, node_context)
    file_path = Path.join(data_dir, interpolated)

    case read_and_parse(file_path) do
      {:ok, data} ->
        case Map.fetch(data, key) do
          {:ok, value} ->
            %{level: level.name, interpolated: interpolated, status: :found, value: value}

          :error ->
            %{level: level.name, interpolated: interpolated, status: :not_found}
        end

      {:error, %Error{category: :not_found}} ->
        %{level: level.name, interpolated: interpolated, status: :not_found}

      {:error, %Error{} = err} ->
        %{level: level.name, interpolated: interpolated, status: :error, error: err}
    end
  end

  defp read_and_parse(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, data} <- parse_yaml(contents) do
      {:ok, data}
    end
  end

  defp resolve_first(chain, key) do
    found = Enum.find(chain, fn e -> e.status == :found end)

    %Resolution{
      key: key,
      result: if(found, do: found.value, else: nil),
      merge_strategy: :first,
      chain: chain
    }
  end

  defp resolve_merge(chain, key, strategy) do
    found_entries = Enum.filter(chain, fn e -> e.status == :found end)
    values = Enum.map(found_entries, & &1.value)

    merged =
      case {strategy, values} do
        {_, []} -> nil
        {:hash, _} -> Enum.reduce(values, %{}, fn v, acc -> Map.merge(v, acc) end)
        {:unique, _} -> values |> List.flatten() |> Enum.uniq()
        {:deep, _} -> Enum.reduce(values, %{}, fn v, acc -> deep_merge(v, acc) end)
      end

    %Resolution{key: key, result: merged, merge_strategy: strategy, chain: chain}
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _k, v1, v2 -> deep_merge(v1, v2) end)
  end

  defp deep_merge(_base, override), do: override

  defp interpolate(pattern, context) when is_map(context) do
    Regex.replace(~r/%\{([^}]+)\}/, pattern, fn _, path ->
      keys = String.split(path, ".")

      case get_nested(context, keys) do
        nil -> "%{#{path}}"
        value -> to_string(value)
      end
    end)
  end

  defp interpolate(pattern, _), do: pattern

  defp get_nested(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      nil -> nil
      value when rest == [] -> value
      value -> get_nested(value, rest)
    end
  end

  defp get_nested(_, _), do: nil
end
