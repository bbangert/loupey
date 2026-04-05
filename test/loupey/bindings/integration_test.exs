defmodule Loupey.Bindings.IntegrationTest do
  @moduledoc """
  Integration test exercising the full binding loop with YAML-defined bindings.

  Run with:
    HA_URL="http://ha.local:8123" HA_TOKEN="..." HA_LIGHT_ENTITY="light.some_light" \
    mix test --include bindings_integration test/loupey/bindings/integration_test.exs

  Requires a connected Loupedeck device and a live Home Assistant instance.

  Loads bindings from YAML fixture files and builds a profile with:
  - Key 0: Light toggle (icon changes with on/off state)
  - Key 1: Exit button
  - Left strip: Brightness slider (fill reflects brightness, touch sets it)
  """

  use ExUnit.Case

  alias Loupey.Bindings.{Engine, Layout, Profile, YamlParser}
  alias Loupey.Device.{Control, Spec}
  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Events.TouchEvent
  alias Loupey.Graphics.Renderer
  alias Loupey.HA
  alias Loupey.HA.{Config, StateCache}
  alias Loupey.RenderCommands.DrawBuffer

  @moduletag :bindings_integration
  @event_timeout_ms 60_000
  @fixtures_dir Path.join(File.cwd!(), "test/fixtures/bindings")

  setup_all do
    url = System.get_env("HA_URL")
    token = System.get_env("HA_TOKEN")
    light_entity = System.get_env("HA_LIGHT_ENTITY")

    devices = Devices.discover()

    cond do
      is_nil(url) or is_nil(token) ->
        IO.puts("\n  HA_URL/HA_TOKEN not set — skipping")
        %{skip: true}

      is_nil(light_entity) ->
        IO.puts("\n  HA_LIGHT_ENTITY not set — skipping")
        %{skip: true}

      devices == [] ->
        IO.puts("\n  No device connected — skipping")
        %{skip: true}

      true ->
        [{driver, tty} | _] = devices
        device_id = "bindings_test"
        {:ok, _} = Devices.connect(driver, tty, device_id: device_id)
        spec = DeviceServer.get_spec(device_id)

        {:ok, _} = HA.connect(%Config{url: url, token: token})
        {:ok, _} = StateCache.subscribe_connected()

        receive do
          :ha_connected -> :ok
        after
          10_000 -> flunk("Timed out waiting for HA connection")
        end

        %{device_id: device_id, spec: spec, light_entity: light_entity}
    end
  end

  setup context do
    if context[:skip], do: :ignore, else: :ok
  end

  test "full binding loop: light toggle + brightness strip + exit", context do
    %{device_id: device_id, spec: spec, light_entity: light_entity} = context

    keys = square_keys(spec)
    assert length(keys) >= 2, "Need at least 2 display keys"

    light_key = Enum.at(keys, 0)
    exit_key = Enum.at(keys, 1)
    left_strip = Spec.find_control(spec, :left_strip)

    # Load bindings from YAML
    {:ok, light_binding} =
      YamlParser.load_binding(
        Path.join(@fixtures_dir, "light_toggle.yaml"),
        %{"entity_id" => light_entity}
      )

    {:ok, exit_binding} =
      YamlParser.load_binding(Path.join(@fixtures_dir, "exit_button.yaml"))

    bindings = %{
      light_key.id => [light_binding],
      exit_key.id => [exit_binding]
    }

    bindings =
      if left_strip do
        {:ok, brightness_binding} =
          YamlParser.load_binding(
            Path.join(@fixtures_dir, "brightness_strip.yaml"),
            %{"entity_id" => light_entity}
          )

        Map.put(bindings, left_strip.id, [brightness_binding])
      else
        bindings
      end

    # Bind top-left knob: rotate for brightness, press to toggle
    {:ok, knob_binding} =
      YamlParser.load_binding(
        Path.join(@fixtures_dir, "brightness_knob.yaml"),
        %{"entity_id" => light_entity}
      )

    bindings = Map.put(bindings, :knob_tl, [knob_binding])

    layout = %Layout{name: "lights", bindings: bindings}

    profile = %Profile{
      name: "Integration Test",
      device_type: spec.type,
      active_layout: "lights",
      layouts: %{"lights" => layout}
    }

    # Start binding engine
    {:ok, _engine} = Engine.start_link(device_id: device_id, profile: profile)

    # Subscribe to device events for exit detection
    {:ok, _} = Devices.subscribe(device_id)

    # Show hints on spare keys
    render_hints(device_id, spec, keys, light_entity, left_strip != nil)

    refresh_displays(device_id, spec)

    IO.puts("\n  Binding engine running with YAML bindings.")
    IO.puts("  Key 0: Light toggle (#{light_entity})")
    IO.puts("  Key 1: Exit test")
    if left_strip, do: IO.puts("  Left strip: Brightness slider (touch to set)")
    IO.puts("  Top-left knob: Rotate for brightness, press to toggle")
    IO.puts("  Touch the exit key to end.\n")

    wait_for_exit(device_id, exit_key.id)

    clear_all_displays(device_id, spec)
    IO.puts("  Test complete.")
  end

  # -- Helpers --

  defp square_keys(spec) do
    spec.controls
    |> Enum.filter(fn c ->
      Control.has_capabilities?(c, [:display]) and
        c.display.width == c.display.height
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp render_hints(device_id, _spec, keys, light_entity, has_strip) do
    hints = [
      {2, light_entity, "#888888"},
      {3, "Touch key 0", "#666666"},
      {4, "to toggle", "#666666"}
    ]

    hints =
      if has_strip do
        hints ++ [{5, "Touch strip", "#666666"}, {6, "for bright", "#666666"}]
      else
        hints
      end

    for {idx, text, color} <- hints, idx < length(keys) do
      key = Enum.at(keys, idx)

      pixels =
        Renderer.render_frame(
          %{background: "#0a0a0a", text: %{content: text, color: color, font_size: 11}},
          key
        )

      DeviceServer.render(device_id, %DrawBuffer{
        control_id: key.id,
        x: 0,
        y: 0,
        width: key.display.width,
        height: key.display.height,
        pixels: pixels
      })
    end
  end

  defp wait_for_exit(device_id, exit_control_id) do
    receive do
      {:device_event, ^device_id, %TouchEvent{control_id: ^exit_control_id, action: :start}} ->
        :ok

      {:device_event, ^device_id, _other_event} ->
        wait_for_exit(device_id, exit_control_id)
    after
      @event_timeout_ms ->
        IO.puts("  Timed out waiting for exit — ending test.")
    end
  end

  defp refresh_displays(device_id, spec) do
    spec.controls
    |> Enum.filter(&Control.has_capability?(&1, :display))
    |> Enum.map(& &1.display.display_id)
    |> Enum.uniq()
    |> Enum.each(&DeviceServer.refresh(device_id, &1))
  end

  defp clear_all_displays(device_id, spec) do
    for control <- Spec.controls_with_capability(spec, :display) do
      pixels = Renderer.render_solid(control, "#000000")

      DeviceServer.render(device_id, %DrawBuffer{
        control_id: control.id,
        x: 0,
        y: 0,
        width: control.display.width,
        height: control.display.height,
        pixels: pixels
      })
    end

    refresh_displays(device_id, spec)
  end
end
