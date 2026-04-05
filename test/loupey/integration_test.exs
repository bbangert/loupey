defmodule Loupey.IntegrationTest do
  @moduledoc """
  Integration test that requires a physical device connected.

  Run with: mix test test/loupey/integration_test.exs

  This test:
  1. Discovers connected supported devices
  2. Connects to the first one
  3. Renders colors, fills, and gradients to all display outputs
  4. Sets LED colors on all LED-capable buttons
  5. Sets display brightness
  6. Waits for user input events (button press, knob rotate, touch)

  The test renders a visible sequence so you can visually verify output,
  then prompts you to interact with the device to verify input.
  """

  use ExUnit.Case

  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Device.{Spec, Control}
  alias Loupey.RenderCommands.{DrawBuffer, SetLED, SetBrightness}
  alias Loupey.Graphics.Renderer
  alias Loupey.Events.{PressEvent, RotateEvent, TouchEvent}

  @moduletag :integration
  @input_timeout_ms 15_000

  setup_all do
    devices = Devices.discover()

    if devices == [] do
      IO.puts("\n  No supported devices found — skipping integration test.")
      %{skip: true}
    else
      [{driver, tty} | _] = devices
      device_id = "integration_test"
      {:ok, _pid} = Devices.connect(driver, tty, device_id: device_id)
      spec = DeviceServer.get_spec(device_id)
      %{device_id: device_id, spec: spec}
    end
  end

  setup %{device_id: device_id, spec: spec} = context do
    if context[:skip] do
      :ignore
    else
      {:ok, _} = Devices.subscribe(device_id)

      on_exit(fn ->
        clear_all_displays(device_id, spec)
        clear_all_leds(device_id, spec)
        Process.sleep(100)
      end)

      :ok
    end
  end

  describe "device discovery" do
    test "finds at least one supported device" do
      devices = Devices.discover()
      assert length(devices) > 0, "No supported devices found"

      for {driver, tty} <- devices do
        IO.puts("  Found: #{inspect(driver)} on #{tty}")
      end
    end
  end

  describe "display rendering" do
    test "renders solid colors to all display keys", %{device_id: id, spec: spec} do
      keys = Spec.controls_with_capability(spec, :display)
      assert length(keys) > 0, "No display controls found"

      colors = ["#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#FF00FF", "#00FFFF"]

      for {control, color} <- Enum.zip(keys, Stream.cycle(colors)) do
        pixels = Renderer.render_solid(control, color)

        cmd = %DrawBuffer{
          control_id: control.id,
          x: 0,
          y: 0,
          width: control.display.width,
          height: control.display.height,
          pixels: pixels
        }

        DeviceServer.render(id, cmd)
      end

      refresh_all_displays(id, spec)
      Process.sleep(1000)

      # Now render black to all
      clear_all_displays(id, spec)
      Process.sleep(200)
    end

    test "renders fill with direction to strips", %{device_id: id, spec: spec} do
      strips =
        spec.controls
        |> Enum.filter(fn c ->
          Control.has_capabilities?(c, [:touch, :display]) and
            c.display.width < c.display.height
        end)

      if strips == [] do
        IO.puts("  No vertical strips found — skipping fill test")
      else
        # Fill left strip bottom-to-top in green at 60%
        for strip <- strips do
          pixels =
            Renderer.render_frame(
              %{
                background: "#111111",
                fill: %{amount: 60, direction: :to_top, color: "#00FF88"}
              },
              strip
            )

          cmd = %DrawBuffer{
            control_id: strip.id,
            x: 0,
            y: 0,
            width: strip.display.width,
            height: strip.display.height,
            pixels: pixels
          }

          DeviceServer.render(id, cmd)
        end

        refresh_all_displays(id, spec)
        Process.sleep(1500)
        clear_all_displays(id, spec)
      end
    end

    test "renders fill with icon on keys", %{device_id: id, spec: spec} do
      keys =
        spec.controls
        |> Enum.filter(fn c ->
          Control.has_capabilities?(c, [:display]) and
            c.display.width == c.display.height
        end)
        |> Enum.take(4)

      fills = [
        %{background: "#220000", fill: %{amount: 30, direction: :to_top, color: "#FF0000"}},
        %{background: "#002200", fill: %{amount: 60, direction: :to_top, color: "#00FF00"}},
        %{background: "#000022", fill: %{amount: 90, direction: :to_top, color: "#0000FF"}},
        %{background: "#222200", fill: %{amount: 100, direction: :to_top, color: "#FFFF00"}}
      ]

      for {control, instructions} <- Enum.zip(keys, fills) do
        pixels = Renderer.render_frame(instructions, control)

        cmd = %DrawBuffer{
          control_id: control.id,
          x: 0,
          y: 0,
          width: control.display.width,
          height: control.display.height,
          pixels: pixels
        }

        DeviceServer.render(id, cmd)
      end

      refresh_all_displays(id, spec)
      Process.sleep(1500)
      clear_all_displays(id, spec)
    end
  end

  describe "LED rendering" do
    test "sets LED colors on all LED buttons", %{device_id: id, spec: spec} do
      led_controls = Spec.controls_with_capability(spec, :led)
      assert length(led_controls) > 0, "No LED controls found"

      colors = ["#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#FF00FF", "#00FFFF", "#FFFFFF", "#FF8800"]

      for {control, color} <- Enum.zip(led_controls, Stream.cycle(colors)) do
        DeviceServer.render(id, %SetLED{control_id: control.id, color: color})
      end

      Process.sleep(1000)

      # Clear LEDs
      clear_all_leds(id, spec)
      Process.sleep(200)
    end
  end

  describe "brightness" do
    test "sets brightness levels", %{device_id: id} do
      for level <- [0.2, 0.5, 0.8, 1.0, 0.5] do
        DeviceServer.render(id, %SetBrightness{level: level})
        Process.sleep(300)
      end
    end
  end

  describe "input events" do
    test "receives button press events", %{device_id: id, spec: spec} do
      # Light up a button to indicate which one to press
      led_controls = Spec.controls_with_capability(spec, :led)

      if led_controls != [] do
        target = hd(led_controls)
        DeviceServer.render(id, %SetLED{control_id: target.id, color: "#00FF00"})
        IO.puts("\n  Press the green lit button within #{div(@input_timeout_ms, 1000)}s...")

        assert_receive {:device_event, ^id, %PressEvent{action: :press}}, @input_timeout_ms
        IO.puts("  Got button press!")

        assert_receive {:device_event, ^id, %PressEvent{action: :release}}, @input_timeout_ms
        IO.puts("  Got button release!")

        DeviceServer.render(id, %SetLED{control_id: target.id, color: "#000000"})
      end
    end

    test "receives knob rotation events", %{device_id: id} do
      IO.puts("\n  Rotate any knob within #{div(@input_timeout_ms, 1000)}s...")

      assert_receive {:device_event, ^id, %RotateEvent{direction: dir}}, @input_timeout_ms
      IO.puts("  Got knob rotation: #{dir}")
    end

    test "receives touch events", %{device_id: id, spec: spec} do
      # Show a color on the first key to indicate where to touch
      keys = Spec.controls_with_capability(spec, :display) |> Enum.take(1)

      if keys != [] do
        target = hd(keys)
        pixels = Renderer.render_solid(target, "#0088FF")

        DeviceServer.render(id, %DrawBuffer{
          control_id: target.id,
          x: 0,
          y: 0,
          width: target.display.width,
          height: target.display.height,
          pixels: pixels
        })

        refresh_all_displays(id, spec)
        IO.puts("\n  Touch the blue key within #{div(@input_timeout_ms, 1000)}s...")

        assert_receive {:device_event, ^id, %TouchEvent{action: :start} = touch}, @input_timeout_ms
        IO.puts("  Got touch start at (#{touch.x}, #{touch.y}) on #{inspect(touch.control_id)}")

        assert_receive {:device_event, ^id, %TouchEvent{action: :end}}, @input_timeout_ms
        IO.puts("  Got touch end!")

        clear_all_displays(id, spec)
      end
    end
  end

  # -- Helpers --

  defp refresh_all_displays(device_id, spec) do
    spec.controls
    |> Enum.filter(&Control.has_capability?(&1, :display))
    |> Enum.map(& &1.display.display_id)
    |> Enum.uniq()
    |> Enum.each(fn display_id ->
      DeviceServer.refresh(device_id, display_id)
    end)
  end

  defp clear_all_displays(device_id, spec) do
    display_controls = Spec.controls_with_capability(spec, :display)

    for control <- display_controls do
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

    refresh_all_displays(device_id, spec)
  end

  defp clear_all_leds(device_id, spec) do
    for control <- Spec.controls_with_capability(spec, :led) do
      DeviceServer.render(device_id, %SetLED{control_id: control.id, color: "#000000"})
    end
  end
end
