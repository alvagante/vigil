defmodule Vigil.Integrations.SSH.FactParser do
  @moduledoc """
  Pure parsers for the baseline fact-gathering command outputs (`SSH-201`,
  `SSH-202`). Each command's stdout is turned into a flat map of dotted fact
  keys. The commands are the POSIX/Linux baseline only — no special tooling on
  the target is assumed. Windows/PowerShell gathering (`SSH-203`) is a future
  transport hook, deferred past #6.

  Values that cannot be parsed are simply omitted rather than guessed, so a
  partial command set still yields whatever facts it can.
  """

  @doc "Parse `/etc/os-release` (KEY=VALUE lines) into os.* facts."
  @spec parse_os_release(String.t()) :: map()
  def parse_os_release(text) do
    kv =
      text
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> {k, unquote_value(v)}
          [k] -> {k, ""}
        end
      end)

    %{}
    |> put_if(kv, "os.distro", "ID")
    |> put_if(kv, "os.name", "NAME")
    |> put_if(kv, "os.version", "VERSION_ID")
    |> put_if(kv, "os.pretty_name", "PRETTY_NAME")
  end

  @doc "Parse `uname -s -r -m` output (kernel name, release, machine)."
  @spec parse_uname(String.t()) :: map()
  def parse_uname(text) do
    case String.split(String.trim(text), ~r/\s+/, trim: true) do
      [name, release, machine | _] ->
        %{"kernel.name" => name, "kernel.release" => release, "architecture" => machine}

      _ ->
        %{}
    end
  end

  @doc "Parse `ip -j addr` JSON into a `network.interfaces` fact."
  @spec parse_ip_json(String.t()) :: map()
  def parse_ip_json(json) do
    case Jason.decode(json) do
      {:ok, interfaces} when is_list(interfaces) ->
        %{"network.interfaces" => Enum.map(interfaces, &interface/1)}

      _ ->
        %{}
    end
  end

  @doc "Parse `/proc/meminfo` for the total memory in kB."
  @spec parse_meminfo(String.t()) :: map()
  def parse_meminfo(text) do
    case Regex.run(~r/^MemTotal:\s+(\d+)\s*kB/m, text) do
      [_, kb] -> %{"memory.total_kb" => String.to_integer(kb)}
      _ -> %{}
    end
  end

  @doc "Parse `nproc` output into a cpu.count fact."
  @spec parse_nproc(String.t()) :: map()
  def parse_nproc(text) do
    case Integer.parse(String.trim(text)) do
      {n, _} -> %{"cpu.count" => n}
      :error -> %{}
    end
  end

  @doc """
  Flatten a map of `command_key => stdout` into a single fact map. Recognised
  keys: `:os_release`, `:uname`, `:ip_json`, `:meminfo`, `:nproc`, `:hostname`,
  `:uptime`. Unknown keys are ignored.
  """
  @spec merge(%{optional(atom()) => String.t()}) :: map()
  def merge(outputs) do
    Enum.reduce(outputs, %{}, fn {key, output}, acc ->
      Map.merge(acc, parse_command(key, output))
    end)
  end

  defp parse_command(:os_release, out), do: parse_os_release(out)
  defp parse_command(:uname, out), do: parse_uname(out)
  defp parse_command(:ip_json, out), do: parse_ip_json(out)
  defp parse_command(:meminfo, out), do: parse_meminfo(out)
  defp parse_command(:nproc, out), do: parse_nproc(out)
  defp parse_command(:hostname, out), do: %{"hostname" => String.trim(out)}
  defp parse_command(:uptime, out), do: %{"uptime" => String.trim(out)}
  defp parse_command(_unknown, _out), do: %{}

  defp interface(%{"ifname" => name} = iface) do
    addresses =
      iface
      |> Map.get("addr_info", [])
      |> Enum.flat_map(fn
        %{"local" => addr} -> [addr]
        _ -> []
      end)

    %{"name" => name, "addresses" => addresses}
  end

  defp interface(_), do: %{"name" => nil, "addresses" => []}

  defp put_if(acc, kv, fact_key, source_key) do
    case Map.get(kv, source_key) do
      nil -> acc
      "" -> acc
      value -> Map.put(acc, fact_key, value)
    end
  end

  defp unquote_value(v) do
    v |> String.trim() |> String.trim("\"")
  end
end
