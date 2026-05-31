defmodule Vigil.Integrations.SSH.ConfigParser do
  @moduledoc """
  Parses OpenSSH client config files into `Vigil.Plugin.Node` inventory entries
  (`SSH-101`..`SSH-105`).

  `parse/1` is a pure function over config text. `parse_file/1` reads a file from
  disk and resolves `Include` directives (`SSH-104`). Keywords are matched
  case-insensitively and accept either whitespace or `=` as the key/value
  separator, matching `ssh_config(5)`.

  Wildcard `Host` patterns (containing `*` or `?`) are configuration directives,
  not connectable destinations, so they are emitted with `targetable?: false`
  (`SSH-103`) — the UI must not offer execute actions against them.
  """

  alias Vigil.Plugin.Node

  @doc "Parse SSH config text into a list of `Vigil.Plugin.Node` entries."
  @spec parse(String.t()) :: [Node.t()]
  def parse(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.map(&strip_comment/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&split_keyword/1)
    |> group_into_hosts()
    |> Enum.flat_map(&to_nodes/1)
  end

  @doc """
  Read and parse a config file, resolving `Include` directives relative to the
  including file's directory. Returns `{:ok, nodes}` or `{:error, reason}`.
  """
  @spec parse_file(Path.t()) :: {:ok, [Node.t()]} | {:error, term()}
  def parse_file(path) do
    do_parse_file(Path.expand(path), MapSet.new())
  end

  defp do_parse_file(path, seen) do
    # Guard against Include cycles: a file already on the path contributes nothing.
    if MapSet.member?(seen, path) do
      {:ok, []}
    else
      with {:ok, content} <- File.read(path) do
        seen = MapSet.put(seen, path)
        own_nodes = parse(content)

        case included_nodes(content, Path.dirname(path), seen) do
          {:ok, extra} -> {:ok, own_nodes ++ extra}
          {:error, _} = err -> err
        end
      end
    end
  end

  # Collect nodes contributed by every `Include` directive in `content`. Each
  # pattern is resolved relative to `base_dir` (or taken as-is when absolute) and
  # may glob to several files.
  defp included_nodes(content, base_dir, seen) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case strip_comment(line) |> split_keyword() do
        {"include", patterns} -> String.split(patterns, ~r/\s+/, trim: true)
        _ -> []
      end
    end)
    |> Enum.flat_map(&expand_include(&1, base_dir))
    |> reduce_files(seen)
  end

  defp expand_include(pattern, base_dir) do
    expanded = if Path.type(pattern) == :absolute, do: pattern, else: Path.join(base_dir, pattern)

    case Path.wildcard(expanded) do
      [] -> [expanded]
      matches -> matches
    end
  end

  defp reduce_files(files, seen) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case do_parse_file(file, seen) do
        {:ok, nodes} -> {:cont, {:ok, acc ++ nodes}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  ## Pure parsing of a single config text (no includes)

  defp strip_comment(line) do
    line
    |> String.replace(~r/#.*$/, "")
    |> String.trim()
  end

  # Split "Keyword value" or "Keyword=value" into {downcased_keyword, value}.
  defp split_keyword(""), do: :blank

  defp split_keyword(line) do
    case Regex.run(~r/^(\S+?)\s*=\s*(.*)$|^(\S+)\s+(.*)$/, line) do
      [_, kw, val] -> {String.downcase(kw), String.trim(val)}
      [_, "", "", kw, val] -> {String.downcase(kw), String.trim(val)}
      _ -> {String.downcase(line), ""}
    end
  end

  # Fold the keyword stream into [{[aliases], %{attrs}}], one tuple per Host block.
  defp group_into_hosts(pairs) do
    pairs
    |> Enum.reduce([], fn
      {"host", aliases}, acc ->
        [{String.split(aliases, ~r/\s+/, trim: true), %{}} | acc]

      {"include", _}, acc ->
        # Includes are handled in parse_file; ignore inside pure parse/1.
        acc

      {key, value}, [{aliases, attrs} | rest] ->
        [{aliases, Map.put(attrs, key, value)} | rest]

      {_key, _value}, [] ->
        # Directives before any Host block apply globally; inventory ignores them.
        []
    end)
    |> Enum.reverse()
  end

  defp to_nodes({aliases, attrs}) do
    Enum.map(aliases, fn alias_name ->
      %Node{
        name: alias_name,
        display_name: alias_name,
        attributes: connection_attributes(alias_name, attrs),
        targetable?: not wildcard?(alias_name)
      }
    end)
  end

  defp connection_attributes(alias_name, attrs) do
    %{
      "hostname" => Map.get(attrs, "hostname", alias_name),
      "port" => attrs |> Map.get("port") |> to_port(),
      "user" => Map.get(attrs, "user"),
      "identity_file" => Map.get(attrs, "identityfile")
    }
  end

  defp to_port(nil), do: nil

  defp to_port(value) do
    case Integer.parse(value) do
      {port, _} -> port
      :error -> nil
    end
  end

  defp wildcard?(name), do: String.contains?(name, "*") or String.contains?(name, "?")
end
