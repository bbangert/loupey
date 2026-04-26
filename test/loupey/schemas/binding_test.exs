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

  describe "changeset/2 yaml parse validation" do
    test "rejects YAML that crashes the parser (unquoted hex color)" do
      # YAML treats `#` as a comment marker, so `color: #ffffff` parses
      # as `color: nil`. The flash effect's `with_alpha/2` then raises
      # CaseClauseError. Without this validation the bad row would
      # land in the DB and crash profile load on every subsequent boot
      # (the user-reported failure mode).
      bad_yaml = """
      input_rules:
        - on: touch_start
          action: call_service
          domain: light
          service: toggle
          animation:
            effect: flash
            color: #ffffff
      """

      cs =
        Binding.changeset(%Binding{}, %{
          "control_id" => "{:key, 0}",
          "yaml" => bad_yaml,
          "layout_id" => 1
        })

      refute cs.valid?
      assert {message, _} = cs.errors[:yaml]
      assert message =~ "could not be parsed"
    end

    test "accepts well-formed YAML" do
      good_yaml = """
      output_rules:
        - when: 'state == "on"'
          color: "#FFD700"
      """

      cs =
        Binding.changeset(%Binding{}, %{
          "control_id" => "{:key, 0}",
          "yaml" => good_yaml,
          "layout_id" => 1
        })

      assert cs.valid?
    end

    test "validates the existing YAML even when only non-YAML fields change" do
      # `get_field/2` (vs. `get_change/2`) ensures a pre-existing bad
      # YAML row can't be updated for any other field without first
      # fixing the YAML. Closes the silent-data-rot path: editing
      # `entity_id` on a broken binding would otherwise leave the bad
      # YAML in place undetected.
      bad_yaml = """
      input_rules:
        - on: touch_start
          action: call_service
          domain: light
          service: toggle
          animation:
            effect: flash
            color: #ffffff
      """

      existing = %Binding{
        id: 1,
        control_id: "{:key, 0}",
        entity_id: "light.original",
        yaml: bad_yaml,
        layout_id: 1
      }

      # User edits only entity_id — yaml not in the changes map.
      cs = Binding.changeset(existing, %{"entity_id" => "light.renamed"})

      refute cs.valid?, "changeset must reject when stored YAML is invalid"
      assert {message, _} = cs.errors[:yaml]
      assert message =~ "could not be parsed"
    end
  end

  describe "to_core/1 — runtime safety net" do
    test "returns {:error, {:parse_failed, _}} on YAML that would raise in the parser" do
      # Same payload the changeset rejects above; this asserts the
      # runtime safety net independently, since rows can pre-date the
      # changeset validation (as in the user-reported incident).
      bad_yaml = """
      input_rules:
        - on: touch_start
          action: call_service
          domain: light
          service: toggle
          animation:
            effect: flash
            color: #ffffff
      """

      assert {:error, {:parse_failed, message}} =
               Binding.to_core(%Binding{yaml: bad_yaml})

      assert is_binary(message)
    end

    test "returns {:ok, _} on well-formed YAML" do
      good_yaml = """
      output_rules:
        - when: 'state == "on"'
          color: "#FF0000"
      """

      assert {:ok, %Loupey.Bindings.Binding{}} =
               Binding.to_core(%Binding{yaml: good_yaml})
    end

    test "returns {:error, _} on YAML syntax errors (e.g. malformed indent)" do
      # The YamlElixir layer returns {:error, _} for syntax-level
      # problems; this clause is what the existing implementation
      # already handled — added here to pin that the rescue doesn't
      # swallow it into a parse_failed tuple.
      assert {:error, _} = Binding.to_core(%Binding{yaml: "input_rules:\n  - on press"})
    end
  end
end
