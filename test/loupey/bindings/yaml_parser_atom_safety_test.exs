defmodule Loupey.Bindings.YamlParserAtomSafetyTest do
  @moduledoc """
  Regression tests for `Loupey.Bindings.YamlParser` atom-exhaustion guards.

  Split out from `YamlParserTest` so the main test module stays
  `async: true` — these tests must be `async: false` because they assert
  on `:erlang.system_info(:atom_count)`, which is global to the VM.
  """

  # async: false — atom-count is global; parallel tests would let unrelated
  # atom creation inflate the delta and flake the assertion.
  use ExUnit.Case, async: false

  alias Loupey.Bindings.YamlParser

  # Warm up any modules/atoms the parser lazy-loads (YamlElixir internals,
  # Binding/InputRule/OutputRule structs, etc.) before sampling
  # `:atom_count`. Without this, the *first* regression test pays a cold-
  # start atom cost unrelated to the behavior under test and flakes the
  # tight `< 50` delta assertion.
  setup do
    {:ok, _} =
      YamlParser.parse_binding("""
      entity_id: "warmup"
      input_rules:
        - on: press
          action: call_service
      output_rules: []
      """)

    :ok
  end

  describe "atom safety (regression)" do
    test "unknown trigger strings do not create new atoms" do
      before_count = :erlang.system_info(:atom_count)
      seed = System.unique_integer([:positive])

      yaml_template = fn trigger ->
        """
        entity_id: "light.x"
        input_rules:
          - on: #{trigger}
            action: call_service
        """
      end

      Enum.each(1..200, fn i ->
        trigger = "never_seen_trigger_#{seed}_#{i}"
        assert {:ok, binding} = YamlParser.parse_binding(yaml_template.(trigger))
        # Unknown trigger falls through as the raw string — downstream
        # Rules.matches?/2 simply won't match. Shape is irrelevant here; we
        # only care that no atom was created.
        [rule] = binding.input_rules
        assert rule.on == trigger
      end)

      assert :erlang.system_info(:atom_count) - before_count < 50,
             "parse_binding/1 created new atoms for unknown triggers — atom-exhaustion regression."
    end

    test "unknown YAML keys do not create new atoms" do
      before_count = :erlang.system_info(:atom_count)
      seed = System.unique_integer([:positive])

      Enum.each(1..200, fn i ->
        yaml = """
        entity_id: "light.x"
        input_rules:
          - on: press
            action: call_service
            never_seen_field_#{seed}_#{i}: "garbage"
        """

        assert {:ok, _binding} = YamlParser.parse_binding(yaml)
      end)

      assert :erlang.system_info(:atom_count) - before_count < 50,
             "atomize_keys/1 created new atoms for unknown YAML keys — atom-exhaustion regression."
    end
  end
end
