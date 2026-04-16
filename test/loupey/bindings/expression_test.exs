defmodule Loupey.Bindings.ExpressionTest do
  use ExUnit.Case, async: true

  alias Loupey.Bindings.Expression
  alias Hassock.EntityState

  defp light_on do
    %EntityState{
      entity_id: "light.living_room",
      state: "on",
      attributes: %{"brightness" => 255, "color_mode" => "brightness"}
    }
  end

  defp light_off do
    %EntityState{entity_id: "light.living_room", state: "off", attributes: %{"brightness" => 0}}
  end

  defp sensor do
    %EntityState{
      entity_id: "sensor.temperature",
      state: "72.5",
      attributes: %{"unit_of_measurement" => "°F"}
    }
  end

  describe "eval/2" do
    test "evaluates simple equality" do
      assert Expression.eval(~s(state == "on"), light_on()) == true
      assert Expression.eval(~s(state == "on"), light_off()) == false
    end

    test "evaluates inequality" do
      assert Expression.eval(~s(state != "off"), light_on()) == true
    end

    test "evaluates attribute access" do
      assert Expression.eval(~s(attributes["brightness"]), light_on()) == 255
    end

    test "evaluates arithmetic with attributes" do
      assert Expression.eval(~s(attributes["brightness"] / 255 * 100), light_on()) == 100.0
    end

    test "returns nil on error" do
      assert Expression.eval("nonexistent_var", light_on()) == nil
    end

    test "handles nil entity state" do
      assert Expression.eval(~s(state == "on"), nil) == false
    end
  end

  describe "eval_condition/2" do
    test "true atom always matches" do
      assert Expression.eval_condition(true, nil) == true
      assert Expression.eval_condition(true, light_on()) == true
    end

    test "nil entity state returns false for non-true conditions" do
      assert Expression.eval_condition(~s(state == "on"), nil) == false
    end

    test "evaluates expression as boolean" do
      assert Expression.eval_condition(~s(state == "on"), light_on()) == true
      assert Expression.eval_condition(~s(state == "on"), light_off()) == false
    end
  end

  describe "render/2" do
    test "replaces template expressions" do
      assert Expression.render("{{ state }}°F", sensor()) == "72.5°F"
    end

    test "handles multiple templates" do
      result = Expression.render("{{ entity_id }}: {{ state }}", sensor())
      assert result == "sensor.temperature: 72.5"
    end

    test "returns non-template strings as-is" do
      assert Expression.render("hello world", light_on()) == "hello world"
    end

    test "replaces failed expressions with empty string" do
      assert Expression.render("{{ bad_var }}", light_on()) == ""
    end
  end

  describe "resolve/2" do
    test "resolves template strings" do
      assert Expression.resolve("{{ state }}", light_on()) == "on"
    end

    test "resolves numeric results" do
      result = Expression.resolve("{{ attributes[\"brightness\"] / 255 * 100 }}", light_on())
      assert result == 100.0
    end

    test "passes through non-template strings" do
      assert Expression.resolve("#FF0000", light_on()) == "#FF0000"
    end

    test "passes through non-string values" do
      assert Expression.resolve(42, light_on()) == 42
      assert Expression.resolve(nil, light_on()) == nil
    end
  end
end
