defmodule Vigil.Core.RBAC.GlobPolicy do
  @moduledoc """
  Glob-to-regex compiler and command policy matcher for RBAC command allowlists.

  Patterns use shell-glob syntax (EXEC-302):
  - `*`  — any sequence within a single argument token (no whitespace)
  - `**` — any sequence across argument boundaries (including whitespace)
  - `?`  — exactly one character
  - Everything else is literal (including `.`)

  Regex metacharacters other than `*` and `?` are rejected at compile time so
  operators writing `service.*` get a clear error instead of silent regex semantics.
  """

  @forbidden ~r/[\\^$+(){}\[\]|]/

  @doc """
  Compiles a glob pattern to a `%Regex{}`. Raises `ArgumentError` if the
  pattern contains regex metacharacters that have no glob equivalent.
  Called at grant/changeset time — never on the hot path.
  """
  def compile!(pattern) when is_binary(pattern) do
    if Regex.match?(@forbidden, pattern) do
      raise ArgumentError,
            "Allowlist patterns must use glob syntax, not regex. Offending pattern: #{inspect(pattern)}"
    end

    # Process order matters:
    # 1. Escape literal . before glob translation introduces its own dots.
    # 2. Stash ** as a null-byte sentinel before translating *.
    # 3. Translate *.
    # 4. Restore **.
    # 5. Translate ?.
    pattern
    |> String.replace(".", "\\.")
    |> String.replace("**", "\x00")
    |> String.replace("*", "[^\\s]*")
    |> String.replace("\x00", ".*")
    |> String.replace("?", ".")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  @doc """
  Evaluates `command` against a `command_policy` map.

  - `nil` policy → always `true` (no restriction).
  - Empty `"allow"` list → open; any non-denied command is permitted (EXEC-302).
  - Non-empty `"allow"` list → closed; command must match at least one allow pattern.
  - `"deny"` patterns are checked first and always win (EXEC-305).
  """
  def matches?(nil, _command), do: true

  def matches?(%{"allow" => allow, "deny" => deny}, command) when is_binary(command) do
    deny_regexes = Enum.map(deny, &compile!/1)
    allow_regexes = Enum.map(allow, &compile!/1)

    cond do
      Enum.any?(deny_regexes, &Regex.match?(&1, command)) -> false
      allow_regexes == [] -> true
      true -> Enum.any?(allow_regexes, &Regex.match?(&1, command))
    end
  end
end
