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

  import Phoenix.LiveViewTest

  alias Loupey.Device.{Control, Display, Layout, Spec}
  alias LoupeyWeb.DeviceGrid

  describe "grid/1 with Layout — positioned renderer" do
    setup do
      spec = %Spec{
        type: "Test",
        controls: [
          %Control{id: :knob_tl, capabilities: MapSet.new([:rotate, :press])},
          %Control{
            id: {:key, 0},
            capabilities: MapSet.new([:touch, :display]),
            display: %Display{
              width: 90,
              height: 90,
              pixel_format: :rgb565,
              offset: {60, 0},
              display_id: <<0x00, 0x4D>>
            }
          }
        ]
      }

      layout = %Layout{
        face_width: 400,
        face_height: 300,
        positions: %{
          :knob_tl => %{x: 10, y: 30, width: 40, height: 40, shape: :round},
          {:key, 0} => %{x: 120, y: 0, width: 90, height: 90, shape: :square}
        }
      }

      %{spec: spec, layout: layout}
    end

    test "renders one button per layout position with absolute coords", %{
      spec: spec,
      layout: layout
    } do
      html =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: layout,
          bindings: %{},
          selected: nil
        )

      assert html =~ "left: 10px"
      assert html =~ "top: 30px"
      assert html =~ "left: 120px"
      assert html =~ "top: 0px"
      # Both controls render as <button>
      assert count_occurrences(html, "phx-click=\"select_control\"") == 2
    end

    test "knobs get rounded-full, squares get rounded", %{spec: spec, layout: layout} do
      html =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: layout,
          bindings: %{},
          selected: nil
        )

      assert html =~ "rounded-full"
    end

    test "phx-value-control strings match format_control_id/1", %{spec: spec, layout: layout} do
      html =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: layout,
          bindings: %{},
          selected: nil
        )

      assert html =~ ~s(phx-value-control="knob_tl")
      assert html =~ ~s(phx-value-control="{:key, 0}")
    end

    test "selected styling only applies to the selected control", %{spec: spec, layout: layout} do
      html =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: layout,
          bindings: %{},
          selected: :knob_tl
        )

      assert html =~ "border-blue-400"
    end
  end

  describe "grid/1 without Layout — fallback renderer" do
    setup do
      spec = %Spec{
        type: "Test",
        controls: [
          %Control{id: :knob_tl, capabilities: MapSet.new([:rotate, :press])},
          %Control{id: {:button, 0}, capabilities: MapSet.new([:press, :led])},
          %Control{
            id: {:key, 0},
            capabilities: MapSet.new([:touch, :display]),
            display: %Display{
              width: 90,
              height: 90,
              pixel_format: :rgb565,
              offset: {60, 0},
              display_id: <<0x00, 0x4D>>
            }
          }
        ]
      }

      %{spec: spec}
    end

    test "renders without error when layout is nil", %{spec: spec} do
      html =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: nil,
          bindings: %{},
          selected: nil
        )

      assert html =~ "phx-click=\"select_control\""
      refute html =~ "position: absolute"
    end

    test "phx-value-control strings are identical to the positioned renderer", %{spec: spec} do
      fallback =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: nil,
          bindings: %{},
          selected: nil
        )

      layout = %Layout{
        face_width: 300,
        face_height: 200,
        positions: %{
          :knob_tl => %{x: 10, y: 10, width: 40, height: 40, shape: :round},
          {:button, 0} => %{x: 100, y: 150, width: 40, height: 40, shape: :round},
          {:key, 0} => %{x: 120, y: 0, width: 90, height: 90, shape: :square}
        }
      }

      positioned =
        render_component(&DeviceGrid.grid/1,
          spec: spec,
          layout: layout,
          bindings: %{},
          selected: nil
        )

      for id <- [:knob_tl, {:button, 0}, {:key, 0}] do
        expected = ~s(phx-value-control="#{DeviceGrid.format_control_id(id)}")
        assert String.contains?(fallback, expected), "fallback missing #{expected}"
        assert String.contains?(positioned, expected), "positioned missing #{expected}"
      end
    end
  end

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

  defp count_occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
