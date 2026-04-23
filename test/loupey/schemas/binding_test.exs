defmodule Loupey.Schemas.BindingTest do
  use ExUnit.Case, async: true

  alias Loupey.Schemas.Binding
  alias LoupeyWeb.DeviceGrid

  describe "changeset/2 control_id format" do
    test "accepts the exact strings emitted by DeviceGrid.format_control_id/1" do
      # Covers every id shape a variant produces today: tuple ids
      # (`{:key, n}`, `{:button, n}`) and atom ids (knobs, strips).
      for id <- [
            {:key, 0},
            {:key, 11},
            {:button, 0},
            :knob_tl,
            :knob_br,
            :left_strip,
            :right_strip
          ] do
        control_id = DeviceGrid.format_control_id(id)
        attrs = %{"control_id" => control_id, "yaml" => "x: 1", "layout_id" => 1}
        cs = Binding.changeset(%Binding{}, attrs)

        assert cs.valid?,
               "expected changeset to accept #{inspect(control_id)} (from #{inspect(id)}), " <>
                 "got errors: #{inspect(cs.errors)}"
      end
    end

    test "rejects clearly malformed control_ids" do
      # `:left_strip` (colon-prefixed) is rejected on purpose — the app's
      # writers emit bare atom names via `DeviceGrid.format_control_id/1`,
      # so accepting the colon form too would create two ways to spell the
      # same binding and let lookups diverge from writes.
      for bad <- ["", "not a control", "{:key}", "{:key, abc}", "knob tl", ":left_strip"] do
        refute Binding.changeset(%Binding{}, %{
                 "control_id" => bad,
                 "yaml" => "x: 1",
                 "layout_id" => 1
               }).valid?,
               "expected changeset to reject #{inspect(bad)}"
      end
    end
  end
end
