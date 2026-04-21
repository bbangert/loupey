defmodule LoupeyWeb.DeviceGridTest do
  @moduledoc """
  Tests for `LoupeyWeb.DeviceGrid` — currently focused on the BLOCKER #3
  regression: `parse_control_id/1` must use `String.to_existing_atom/1`
  with a fallback so a hostile or malformed `phx-value-control` value
  cannot exhaust the atom table.
  """

  # async: false — this module asserts on `:erlang.system_info(:atom_count)`,
  # which is global to the VM. Running in parallel with other tests lets
  # unrelated atom creation inflate the delta and flake the assertion.
  use ExUnit.Case, async: false

  alias LoupeyWeb.DeviceGrid

  describe "parse_control_id/1 (BLOCKER #3 regression)" do
    test "parses a known tuple control id (positive path)" do
      # `:key` is a real control-id atom defined by every variant's spec,
      # so it exists in the atom table at runtime and `to_existing_atom`
      # succeeds.
      assert DeviceGrid.parse_control_id("{:key, 3}") == {:key, 3}
    end

    test "parses a known plain-atom control id (positive path)" do
      # `:left_strip` is defined by Loupedeck's variant spec.
      assert DeviceGrid.parse_control_id(":left_strip") == :left_strip or
               DeviceGrid.parse_control_id("left_strip") == :left_strip
    end

    test "unknown tuple control id falls back to the raw string without raising" do
      input = "{:fake_atom_that_does_not_exist_anywhere_in_loupey, 5}"
      assert DeviceGrid.parse_control_id(input) == input
    end

    test "unknown plain control id falls back to the raw string without raising" do
      input = "totally_made_up_control_name_xyz_42"
      assert DeviceGrid.parse_control_id(input) == input
    end

    test "does not create new atoms for unknown inputs" do
      # If `parse_control_id/1` ever reverts to `String.to_atom/1`, an
      # attacker (or a bug) could feed unbounded distinct strings via
      # `phx-value-control` and crash the VM by exhausting the atom table.
      # This test catches that regression by asserting the atom-table size
      # is unchanged after parsing many distinct unknown inputs.

      before_count = :erlang.system_info(:atom_count)

      # Generate inputs that have NEVER existed as atoms anywhere in the
      # codebase, in both tuple and plain forms. Use unique-integer suffix
      # so reruns don't accidentally collide with atoms created on a
      # previous test run.
      seed = System.unique_integer([:positive])

      for i <- 1..200 do
        tuple_form = "{:never_seen_atom_#{seed}_#{i}, #{i}}"
        plain_form = "never_seen_atom_plain_#{seed}_#{i}"

        # Both should fall back to the raw string — no atom creation.
        assert DeviceGrid.parse_control_id(tuple_form) == tuple_form
        assert DeviceGrid.parse_control_id(plain_form) == plain_form
      end

      after_count = :erlang.system_info(:atom_count)

      # Allow a small headroom for incidental atom creation by ExUnit /
      # logger / instrumentation — but well below the 400 distinct unknown
      # inputs we just fed in. The fix would create 400 atoms; the bug
      # would create thousands over time.
      assert after_count - before_count < 50,
             "parse_control_id/1 created #{after_count - before_count} new atoms " <>
               "for 400 unknown inputs — atom-exhaustion regression. " <>
               "The function must use String.to_existing_atom/1 with a rescue."
    end
  end
end
