defmodule Loupey.Bindings.Expression.EvaluatorTest do
  @moduledoc """
  Happy-path tests for `Loupey.Bindings.Expression.Evaluator`.

  Covers every grammar form actually used in `priv/blueprints/*.yaml` and
  `test/fixtures/bindings/*.yaml` (see the grammar-inventory scratchpad).
  Negative / security tests live in `evaluator_security_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Loupey.Bindings.Expression.Evaluator

  # Helper: parse + eval in one call, returning the unwrapped value or
  # raising on error. Keeps tests readable for the common case.
  defp eval!(source, context \\ %{}) do
    case Evaluator.evaluate(source, context) do
      {:ok, v} -> v
      {:error, reason} -> flunk("unexpected error: #{inspect(reason)} for `#{source}`")
    end
  end

  defp ctx(extra \\ %{}) do
    Map.merge(
      %{
        state: "on",
        attributes: %{"brightness" => 128, "volume" => 0.5},
        entity_id: "light.office",
        touch_x: 10,
        touch_y: 45,
        strip_width: 90,
        strip_height: 90,
        state_of: fn
          "light.office" -> "on"
          "light.kitchen" -> "off"
          _ -> nil
        end,
        attr_of: fn
          "light.office", "brightness" -> 200
          _, _ -> nil
        end
      },
      extra
    )
  end

  describe "literals" do
    test "integer" do
      assert eval!("42") == 42
    end

    test "float" do
      assert eval!("3.14") == 3.14
    end

    test "string" do
      assert eval!(~s("hello")) == "hello"
    end

    test "true / false / nil" do
      assert eval!("true") == true
      assert eval!("false") == false
      assert eval!("nil") == nil
    end
  end

  describe "variables" do
    test "resolves from context" do
      assert eval!("state", ctx()) == "on"
      assert eval!("entity_id", ctx()) == "light.office"
      assert eval!("touch_y", ctx()) == 45
    end

    test "missing variable resolves to nil (matches Code.eval_string rescue)" do
      assert eval!("totally_undefined_var", ctx()) == nil
    end
  end

  describe "comparisons" do
    test "== on strings" do
      assert eval!(~s(state == "on"), ctx()) == true
      assert eval!(~s(state == "off"), ctx()) == false
    end

    test "!= on strings" do
      assert eval!(~s(state != "playing"), ctx()) == true
    end

    test "ordering ops on numbers" do
      assert eval!("touch_y > 40", ctx()) == true
      assert eval!("touch_y < 40", ctx()) == false
      assert eval!("touch_y >= 45", ctx()) == true
      assert eval!("touch_y <= 45", ctx()) == true
    end
  end

  describe "arithmetic" do
    test "subtract" do
      assert eval!("100 - 5") == 95
    end

    test "divide" do
      assert eval!("strip_height / 2", ctx()) == 45.0
    end

    test "multiply" do
      assert eval!("touch_y * 2", ctx()) == 90
    end

    test "add" do
      assert eval!("touch_x + touch_y", ctx()) == 55
    end

    test "unary minus" do
      assert eval!("-touch_y", ctx()) == -45
    end

    test "complex nested math (from brightness_slider.yaml)" do
      # round((1 - touch_y / strip_height) * 255) with touch_y=45, strip_height=90
      assert eval!("round((1 - touch_y / strip_height) * 255)", ctx()) == 128
    end
  end

  describe "|| short-circuit default" do
    test "returns LHS when truthy" do
      assert eval!(~s(state || "fallback"), ctx()) == "on"
    end

    test "returns RHS when LHS is nil" do
      assert eval!(~s(totally_undefined || "fallback"), ctx()) == "fallback"
    end

    test "returns RHS when LHS is false" do
      assert eval!(~s(false || "fallback")) == "fallback"
    end

    test "does NOT evaluate RHS when LHS is truthy" do
      # If the walker eagerly evaluated the RHS, attr_of/2 would fire for
      # "never_called" and we could observe it via a tracer — but here we
      # just rely on the behavior-level contract: if RHS were evaluated we
      # would NOT be able to short-circuit nil into a default.
      context =
        ctx(%{
          attr_of: fn
            "sensor.real", key -> Map.get(%{"brightness" => 100}, key)
            _, _ -> raise "should not be called"
          end
        })

      source = ~s<attr_of("sensor.real", "brightness") || attr_of("other", "x")>
      assert eval!(source, context) == 100
    end
  end

  describe "map access via map[key]" do
    test "reads key from attributes map" do
      assert eval!(~s(attributes["brightness"]), ctx()) == 128
    end

    test "missing key resolves to nil" do
      assert eval!(~s(attributes["nope"]), ctx()) == nil
    end

    test "combined with || default (from brightness_slider.yaml)" do
      assert eval!(~s(attributes["brightness"] || 0), ctx()) == 128
      assert eval!(~s(attributes["missing"] || 0), ctx()) == 0
    end
  end

  describe "local calls" do
    test "state_of/1" do
      assert eval!(~s|state_of("light.office")|, ctx()) == "on"
      assert eval!(~s|state_of("light.kitchen")|, ctx()) == "off"
      assert eval!(~s|state_of("unknown.entity")|, ctx()) == nil
    end

    test "attr_of/2" do
      assert eval!(~s|attr_of("light.office", "brightness")|, ctx()) == 200
      assert eval!(~s|attr_of("light.office", "missing")|, ctx()) == nil
    end

    test "round/1" do
      assert eval!("round(3.7)") == 4
      assert eval!("round(3.4)") == 3
    end

    test "state_of composed with ==" do
      assert eval!(~s|state_of("light.office") == "on"|, ctx()) == true
      assert eval!(~s|state_of("light.office") == "off"|, ctx()) == false
    end
  end

  describe "full-blueprint expressions (regression)" do
    test "brightness percentage formula" do
      context = ctx(%{attributes: %{"brightness" => 128}})
      assert eval!(~s<round((attributes["brightness"] || 0) / 255 * 100)>, context) == 50
    end

    test "handles nil attributes gracefully via ||" do
      context = ctx(%{attributes: %{}})
      assert eval!(~s<round((attributes["brightness"] || 0) / 255 * 100)>, context) == 0
    end

    test ~s/media play condition: state == "playing"/ do
      context = ctx(%{state: "playing"})
      assert eval!(~s(state == "playing"), context) == true
      assert eval!(~s(state != "playing"), context) == false
    end
  end

  describe "parse/1 + eval/2 (two-phase for caching)" do
    test "parsed AST can be evaluated many times against different contexts" do
      {:ok, ast} = Evaluator.parse(~s(state == "on"))

      assert {:ok, true} = Evaluator.eval(ast, %{state: "on"})
      assert {:ok, false} = Evaluator.eval(ast, %{state: "off"})
      assert {:ok, false} = Evaluator.eval(ast, %{state: nil})
    end

    test "parse/1 returns an opaque tagged-tuple AST (shape contract)" do
      {:ok, ast} = Evaluator.parse("state")
      assert ast == {:var, :state}

      {:ok, ast} = Evaluator.parse("42")
      assert ast == {:lit, 42}

      {:ok, ast} = Evaluator.parse(~s("hello"))
      assert ast == {:lit, "hello"}
    end
  end

  describe "error handling (non-security)" do
    test "syntax error returns {:error, {:parse, _}}" do
      assert {:error, {:parse, _}} = Evaluator.parse("state ==")
    end

    test "division by zero surfaces as {:error, {:eval, _}}" do
      assert {:error, {:eval, _}} = Evaluator.evaluate("1 / 0", %{})
    end

    test "access on non-map value surfaces as {:error, {:eval, _}}" do
      assert {:error, {:eval, _}} = Evaluator.evaluate(~s("string"["key"]), %{})
    end
  end
end
