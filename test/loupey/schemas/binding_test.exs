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

    test "accepts legacy colon-prefixed atom strings" do
      # Rows written before format_control_id dropped the leading colon
      # should still validate, so existing data isn't orphaned.
      attrs = %{"control_id" => ":left_strip", "yaml" => "x: 1", "layout_id" => 1}
      assert Binding.changeset(%Binding{}, attrs).valid?
    end

    test "rejects clearly malformed control_ids" do
      for bad <- ["", "not a control", "{:key}", "{:key, abc}", "knob tl"] do
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
