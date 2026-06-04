defmodule Vigil.Integrations.Bolt.CLI.PortTest do
  use ExUnit.Case, async: true

  alias Vigil.Integrations.Bolt.CLI.Port, as: BoltPort

  @echo System.find_executable("echo") || "/bin/echo"
  @sleep System.find_executable("sleep") || "/bin/sleep"
  @sh System.find_executable("sh") || "/bin/sh"

  describe "run/3 — happy path" do
    test "returns {:ok, ...} with stdout and zero exit status" do
      assert {:ok, %{exit_status: 0, stdout: stdout, stderr: ""}} =
               BoltPort.run(@echo, ["hello"], wall_clock_ms: 5_000, idle_ms: 5_000)

      assert String.trim(stdout) == "hello"
    end

    test "returns {:error, :not_found} when executable does not exist" do
      assert {:error, :not_found} =
               BoltPort.run("no-such-bolt-executable-xyz", [],
                 wall_clock_ms: 100,
                 idle_ms: 100
               )
    end
  end

  describe "run/3 — wall-clock timeout (BOLT-301)" do
    test "returns {:error, :timeout} and completes quickly" do
      start = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               BoltPort.run(@sleep, ["10"], wall_clock_ms: 150, idle_ms: 5_000)

      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed < 1_000, "expected timeout in ~150ms, took #{elapsed}ms"
    end

    test "kills the directly-spawned process on wall-clock timeout" do
      marker = "/tmp/bolt_port_wall_test_#{System.unique_integer([:positive])}"

      # Script sleeps 1s then creates a marker file.  If the direct child sh is
      # killed the marker is never created.  Background grandchildren (e.g. SSH
      # spawned by bolt) are NOT covered — process-tree reaping is deferred to #15.
      script = "sleep 1; touch #{marker}"

      assert {:error, :timeout} =
               BoltPort.run(@sh, ["-c", script], wall_clock_ms: 150, idle_ms: 5_000)

      Process.sleep(1_500)

      refute File.exists?(marker),
             "directly-spawned sh was not killed — sentinel file was created after timeout"
    end
  end

  describe "run/3 — idle timeout (BOLT-301)" do
    test "returns {:error, :timeout} when no output arrives within idle window" do
      start = System.monotonic_time(:millisecond)

      # sleep produces no output — idle timer will fire first.
      assert {:error, :timeout} =
               BoltPort.run(@sleep, ["10"], wall_clock_ms: 5_000, idle_ms: 150)

      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed < 1_000, "expected idle timeout in ~150ms, took #{elapsed}ms"
    end

    test "kills the directly-spawned process on idle timeout" do
      marker = "/tmp/bolt_port_idle_test_#{System.unique_integer([:positive])}"

      script = "sleep 1; touch #{marker}"

      assert {:error, :timeout} =
               BoltPort.run(@sh, ["-c", script], wall_clock_ms: 5_000, idle_ms: 150)

      Process.sleep(1_500)

      refute File.exists?(marker),
             "directly-spawned sh was not killed — sentinel file was created after idle timeout"
    end
  end
end
