defmodule Vigil.Core.Execution.StreamTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Execution.Stream

  defmodule HangingRunner do
    def start(_integration_id, _artifact, _targets, _opts),
      do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}

    def abort(pid), do: Process.exit(pid, :kill)
  end

  describe "cap_transcript/2" do
    test "returns transcript unchanged when under the cap" do
      data = "normal output\n"
      assert Stream.cap_transcript(data, 100) == data
    end

    test "truncates at cap and appends a truncation marker when over the cap" do
      data = String.duplicate("x", 200)
      result = Stream.cap_transcript(data, 100)

      assert byte_size(result) > 100
      assert String.starts_with?(result, String.duplicate("x", 100))
      assert result =~ "TRUNCATED"
    end

    test "defaults cap to 50 MB" do
      small = "small"
      assert Stream.cap_transcript(small) == small
    end
  end

  describe "via/1 registry naming" do
    test "returns a via-tuple keyed on execution_group_id" do
      assert {:via, Registry, {Vigil.Core.Execution.Registry, "group-xyz"}} =
               Stream.via("group-xyz")
    end
  end

  describe "spool and get_buffer/3 (STR-103)" do
    setup do
      group_id = "spool-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Stream.start_link(%{
          runner_module: HangingRunner,
          integration_id: "integ-spool",
          artifact: %{kind: :command, text: "test"},
          group_id: group_id,
          targets: []
        })

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{group_id: group_id, pid: pid}
    end

    test "chunks have monotonic positions and are returned in order", %{
      group_id: group_id,
      pid: pid
    } do
      send(pid, {:runner_chunk, "exec-1", :stdout, "line 1\n"})
      send(pid, {:runner_chunk, "exec-1", :stdout, "line 2\n"})

      assert [{1, :stdout, "line 1\n"}, {2, :stdout, "line 2\n"}] =
               Stream.get_buffer(group_id, "exec-1", 0)
    end

    test "since_position filters out already-seen chunks", %{group_id: group_id, pid: pid} do
      send(pid, {:runner_chunk, "exec-1", :stdout, "old\n"})
      send(pid, {:runner_chunk, "exec-1", :stdout, "new\n"})

      assert [{2, :stdout, "new\n"}] = Stream.get_buffer(group_id, "exec-1", 1)
    end

    test "different execution_ids have independent spools", %{group_id: group_id, pid: pid} do
      send(pid, {:runner_chunk, "exec-1", :stdout, "target1\n"})
      send(pid, {:runner_chunk, "exec-2", :stdout, "target2\n"})

      assert [{1, :stdout, "target1\n"}] = Stream.get_buffer(group_id, "exec-1", 0)
      assert [{1, :stdout, "target2\n"}] = Stream.get_buffer(group_id, "exec-2", 0)
    end
  end

  describe "grace timer" do
    test "stream stays alive during grace window then exits normally" do
      group_id = "grace-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Stream.start_link(%{
          runner_module: HangingRunner,
          integration_id: "integ-grace",
          artifact: %{kind: :command, text: "test"},
          group_id: group_id,
          targets: [],
          timeout: %{grace_timer_ms: 200}
        })

      ref = Process.monitor(pid)
      send(pid, {:runner_done, %{overall_status: :ok}})

      # Must still be alive inside the grace window.
      Process.sleep(50)
      assert Process.alive?(pid)

      # Must exit normally after the grace window expires.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  describe "ack/4 and subscriber positions (STR-202)" do
    setup do
      group_id = "ack-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Stream.start_link(%{
          runner_module: HangingRunner,
          integration_id: "integ-ack",
          artifact: %{kind: :command, text: "test"},
          group_id: group_id,
          targets: []
        })

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{group_id: group_id, pid: pid}
    end

    test "ack/4 records subscriber position; reconnect via get_buffer returns only newer chunks",
         %{group_id: group_id, pid: pid} do
      send(pid, {:runner_chunk, "exec-1", :stdout, "old\n"})
      send(pid, {:runner_chunk, "exec-1", :stdout, "old2\n"})

      Stream.ack(group_id, "exec-1", self(), 2)

      send(pid, {:runner_chunk, "exec-1", :stdout, "new\n"})

      # Reconnect from last ack position — should get only chunks after pos 2.
      assert [{3, :stdout, "new\n"}] = Stream.get_buffer(group_id, "exec-1", 2)
    end
  end

  describe "spool cap (DM-604)" do
    @small_cap 20

    setup do
      group_id = "spool-cap-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Stream.start_link(%{
          runner_module: HangingRunner,
          integration_id: "integ-cap",
          artifact: %{kind: :command, text: "test"},
          group_id: group_id,
          targets: [],
          spool_cap_bytes: @small_cap
        })

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{group_id: group_id, pid: pid}
    end

    test "truncates spool at cap and appends truncation marker", %{
      group_id: group_id,
      pid: pid
    } do
      # 15 bytes — under cap
      send(pid, {:runner_chunk, "exec-1", :stdout, "123456789012345"})
      # 10 bytes — pushes over the 20-byte cap
      send(pid, {:runner_chunk, "exec-1", :stdout, "ABCDEFGHIJ"})
      # Should be silently dropped
      send(pid, {:runner_chunk, "exec-1", :stdout, "should not appear"})

      chunks = Stream.get_buffer(group_id, "exec-1", 0)

      assert {1, :stdout, "123456789012345"} = hd(chunks)
      assert Enum.any?(chunks, fn {_, _, text} -> text =~ "TRUNCATED" end)
      refute Enum.any?(chunks, fn {_, _, text} -> text =~ "should not appear" end)
    end

    test "chunks below cap are returned normally", %{group_id: group_id, pid: pid} do
      send(pid, {:runner_chunk, "exec-1", :stdout, "hi"})

      assert [{1, :stdout, "hi"}] = Stream.get_buffer(group_id, "exec-1", 0)
    end

    test "different execution_ids have independent caps", %{group_id: group_id, pid: pid} do
      # Exhaust cap on exec-1
      send(pid, {:runner_chunk, "exec-1", :stdout, "123456789012345"})
      send(pid, {:runner_chunk, "exec-1", :stdout, "ABCDEFGHIJ"})
      # exec-2 should still accept data normally
      send(pid, {:runner_chunk, "exec-2", :stdout, "fresh"})

      chunks2 = Stream.get_buffer(group_id, "exec-2", 0)
      assert [{1, :stdout, "fresh"}] = chunks2
    end
  end

  describe "named GenServer — findable and callable" do
    setup do
      group_id = "stream-reg-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Stream.start_link(%{
          runner_module: HangingRunner,
          integration_id: "integ-reg",
          artifact: %{kind: :command, text: "test"},
          group_id: group_id,
          targets: []
        })

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{group_id: group_id, pid: pid}
    end

    test "whereis returns the pid for the group_id", %{group_id: group_id, pid: pid} do
      assert GenServer.whereis(Stream.via(group_id)) == pid
    end

    test "get_buffer/3 returns empty list before any chunks", %{group_id: group_id} do
      assert [] = Stream.get_buffer(group_id, "exec-1", 0)
    end

    test "ack/4 does not crash", %{group_id: group_id} do
      assert :ok = Stream.ack(group_id, "exec-1", self(), 0)
    end

    test "drain/2 returns :ok", %{pid: pid} do
      assert :ok = Stream.drain(pid, 5_000)
    end
  end
end
