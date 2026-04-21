defmodule Loupey.OrchestratorTest do
  @moduledoc """
  Tests for `Loupey.Orchestrator`.

  The broader orchestrator-test harness (activate / deactivate / reload with
  real DB + device fixtures) is tracked under the `loupey-hygiene-sweep` plan
  (Phase 8). This file currently covers just the BLOCKER #4 regression:
  the Engine child spec must use `restart: :transient` so that
  `DynamicSupervisor.terminate_child/2` actually stops the engine.
  """

  # async: false — these tests interact with the globally-named
  # `Loupey.DeviceSupervisor` (a real production process). Running them in
  # parallel with other tests would cause state-bleed via that shared
  # supervisor; keep them serial.
  use ExUnit.Case, async: false

  # Tiny dummy GenServer used as a `:transient` child under the real
  # DeviceSupervisor. Defined at module level (rather than inside a
  # `describe` block) so the full module name appears cleanly in stack traces.
  defmodule TransientProbe do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  describe "engine restart strategy (BLOCKER #4 regression)" do
    test "a :transient child under Loupey.DeviceSupervisor is stopped by terminate_child and does not restart" do
      child_spec = %{
        id: :orchestrator_test_probe,
        start: {TransientProbe, :start_link, [[]]},
        restart: :transient
      }

      {:ok, pid} = DynamicSupervisor.start_child(Loupey.DeviceSupervisor, child_spec)

      # Defensive cleanup: if any assertion below fails before we call
      # terminate_child, this keeps the probe from leaking into the
      # production supervisor for the remainder of the test run.
      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(Loupey.DeviceSupervisor, pid)
        end
      end)

      ref = Process.monitor(pid)
      assert Process.alive?(pid)

      assert :ok = DynamicSupervisor.terminate_child(Loupey.DeviceSupervisor, pid)

      # `:DOWN` arriving means the supervisor has already made its restart
      # decision — a `:permanent` policy would have re-spawned synchronously
      # before this message was delivered. No sleep needed.
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      refute Process.alive?(pid)

      # Filter by `modules` rather than pid: a restart would produce a new
      # pid and the pid-equality check would still pass. (`DynamicSupervisor`
      # always returns `:undefined` for the id element, so that can't be
      # used either — `modules` is the actionable identifier here.)
      children = DynamicSupervisor.which_children(Loupey.DeviceSupervisor)

      refute Enum.any?(children, fn {_id, _p, _type, modules} ->
               __MODULE__.TransientProbe in modules
             end)
    end

    test "orchestrator.ex declares the engine child spec with restart: :transient" do
      # Source-match guard: if `start_or_update_engine/2` ever reverts to
      # `:permanent` (the original bug), this test fails loudly.
      #
      # Absolute path (not cwd-relative) so the test can't silently fail
      # when `mix test` is invoked from a non-root directory.
      source_path = Path.expand("../../lib/loupey/orchestrator.ex", __DIR__)
      source = File.read!(source_path)

      # Capture the full `child_spec = %{...}` block, then assert on its
      # contents field-order-agnostically. Elixir map literals have no
      # guaranteed key ordering, so a stricter ordered regex would be
      # fragile against future reformats.
      engine_spec_block =
        case Regex.run(~r/child_spec\s*=\s*%\{(.*?)\n\s*\}/s, source) do
          [_full, inner] ->
            inner

          nil ->
            flunk(
              "Could not locate the `child_spec = %{...}` block in " <>
                "lib/loupey/orchestrator.ex. Did the engine child spec move?"
            )
        end

      assert engine_spec_block =~ ~r/id:\s*\{:engine,\s*device_id\}/,
             "Expected to find the engine child_spec (id: {:engine, device_id}). " <>
               "Did the spec move to a different location in orchestrator.ex?"

      assert engine_spec_block =~ ~r/restart:\s*:transient/,
             "Expected the engine child_spec in Loupey.Orchestrator to use " <>
               "`restart: :transient`. If you changed the spec, update this test."

      refute engine_spec_block =~ ~r/restart:\s*:permanent/,
             "Found `restart: :permanent` on the engine child_spec. This was " <>
               "BLOCKER #4 — deactivating a profile will silently re-spawn " <>
               "the engine instead of stopping it. Use `:transient`."
    end
  end
end
