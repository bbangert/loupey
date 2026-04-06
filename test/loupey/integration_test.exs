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

  alias Loupey.Device.{Control, Spec}
  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Events.{PressEvent, RotateEvent, TouchEvent}
  alias Loupey.Graphics.Renderer
  alias Loupey.RenderCommands.{DrawBuffer, SetBrightness, SetLED}

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
      :ok = Devices.subscribe(device_id)

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
      assert devices != [], "No supported devices found"

      for {driver, tty} <- devices do
        IO.puts("  Found: #{inspect(driver)} on #{tty}")
      end
    end
  end

  describe "display rendering" do
    test "renders solid colors to all display keys", %{device_id: id, spec: spec} do
      keys = Spec.controls_with_capability(spec, :display)
      assert keys != [], "No display controls found"

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

    test "renders icons from icons/ directory across display keys in pages", %{device_id: id, spec: spec} do
      icon_dir = Path.join(File.cwd!(), "icons")

      icon_paths =
        if File.dir?(icon_dir) do
          icon_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".png"))
          |> Enum.sort()
          |> Enum.map(&Path.join(icon_dir, &1))
        else
          []
        end

      if icon_paths == [] do
        IO.puts("  No icons found in icons/ directory — skipping")
      else
        # Get all square display keys (the main button grid)
        keys =
          spec.controls
          |> Enum.filter(fn c ->
            Control.has_capabilities?(c, [:display]) and
              c.display.width == c.display.height
          end)
          |> Enum.sort_by(fn c -> c.id end)

        key_count = length(keys)
        assert key_count > 0, "No square display keys found"

        pages = Enum.chunk_every(icon_paths, key_count)
        total_pages = length(pages)
        IO.puts("\n  Rendering #{length(icon_paths)} icons across #{total_pages} pages of #{key_count} keys...")

        backgrounds = Stream.cycle(["#1a1a2e", "#16213e", "#0f3460", "#1a0a2e", "#2e1a0a", "#0a2e1a"])

        for {page, page_idx} <- Enum.with_index(pages) do
          # Render each icon in this page to a key
          for {icon_path, key} <- Enum.zip(page, keys) do
            max_dim = min(key.display.width, key.display.height) - 10
            icon_image = Image.thumbnail!(icon_path, max_dim)
            bg_color = Enum.at(backgrounds, page_idx)

            pixels = Renderer.render_frame(%{background: bg_color, icon: icon_image}, key)

            DeviceServer.render(id, %DrawBuffer{
              control_id: key.id,
              x: 0,
              y: 0,
              width: key.display.width,
              height: key.display.height,
              pixels: pixels
            })
          end

          # If this page has fewer icons than keys, clear the remaining keys
          remaining = Enum.drop(keys, length(page))

          for key <- remaining do
            pixels = Renderer.render_solid(key, "#000000")

            DeviceServer.render(id, %DrawBuffer{
              control_id: key.id,
              x: 0,
              y: 0,
              width: key.display.width,
              height: key.display.height,
              pixels: pixels
            })
          end

          refresh_all_displays(id, spec)
          IO.puts("  Page #{page_idx + 1}/#{total_pages}")
          Process.sleep(1500)
        end

        clear_all_displays(id, spec)
        Process.sleep(200)
      end
    end
  end

  describe "text rendering" do
    test "renders text labels on display keys", %{device_id: id, spec: spec} do
      keys =
        spec.controls
        |> Enum.filter(fn c ->
          Control.has_capabilities?(c, [:display]) and
            c.display.width == c.display.height
        end)
        |> Enum.sort_by(& &1.id)

      labels = [
        %{text: "Play", background: "#1a2e1a"},
        %{text: "Pause", background: "#2e1a1a"},
        %{text: "Stop", background: "#1a1a2e"},
        %{text: %{content: "Mute", color: "#FF4444", font_size: 18}, background: "#2e0a0a"},
        %{text: %{content: "Vol+", color: "#44FF44", font_size: 20}, background: "#0a2e0a"},
        %{text: %{content: "Vol-", color: "#4444FF", font_size: 20}, background: "#0a0a2e"},
        %{text: %{content: "TOP", color: "#FFAA00", font_size: 14, valign: :top}, background: "#1a1a1a"},
        %{text: %{content: "BTM", color: "#FFAA00", font_size: 14, valign: :bottom}, background: "#1a1a1a"},
        %{text: %{content: "LEFT", color: "#00AAFF", font_size: 12, align: :left}, background: "#1a1a1a"},
        %{text: %{content: "RIGHT", color: "#00AAFF", font_size: 12, align: :right}, background: "#1a1a1a"},
        %{text: %{content: "BIG", color: "#FFFFFF", font_size: 28}, background: "#2e1a2e"},
        %{text: %{content: "tiny", color: "#888888", font_size: 10}, background: "#111111"}
      ]

      for {control, instructions} <- Enum.zip(keys, labels) do
        pixels = Renderer.render_frame(instructions, control)

        DeviceServer.render(id, %DrawBuffer{
          control_id: control.id,
          x: 0,
          y: 0,
          width: control.display.width,
          height: control.display.height,
          pixels: pixels
        })
      end

      refresh_all_displays(id, spec)
      IO.puts("\n  Displaying text labels on keys...")
      Process.sleep(2000)
      clear_all_displays(id, spec)
    end

    test "renders text with icons on keys", %{device_id: id, spec: spec} do
      icon_dir = Path.join(File.cwd!(), "icons")

      keys =
        spec.controls
        |> Enum.filter(fn c ->
          Control.has_capabilities?(c, [:display]) and
            c.display.width == c.display.height
        end)
        |> Enum.sort_by(& &1.id)
        |> Enum.take(6)

      icon_labels = [
        {"Audio_On.png", "On"},
        {"Audio_Off.png", "Off"},
        {"Mic_On.png", "Mic"},
        {"Play.png", "Play"},
        {"Pause.png", "Pause"},
        {"Stop.png", "Stop"}
      ]

      for {{icon_file, label}, control} <- Enum.zip(icon_labels, keys) do
        icon_path = Path.join(icon_dir, icon_file)

        if File.exists?(icon_path) do
          max_dim = control.display.width - 20
          icon_image = Image.thumbnail!(icon_path, max_dim)

          pixels =
            Renderer.render_frame(
              %{
                background: "#111122",
                icon: icon_image,
                text: %{content: label, color: "#CCCCCC", font_size: 12, valign: :bottom}
              },
              control
            )

          DeviceServer.render(id, %DrawBuffer{
            control_id: control.id,
            x: 0,
            y: 0,
            width: control.display.width,
            height: control.display.height,
            pixels: pixels
          })
        end
      end

      refresh_all_displays(id, spec)
      IO.puts("\n  Displaying icons with text labels...")
      Process.sleep(2000)
      clear_all_displays(id, spec)
    end

    test "renders vertical text on strips", %{device_id: id, spec: spec} do
      strips =
        spec.controls
        |> Enum.filter(fn c ->
          Control.has_capabilities?(c, [:display]) and
            c.display.width < c.display.height
        end)

      if strips == [] do
        IO.puts("  No vertical strips — skipping")
      else
        strip_labels = [
          %{
            background: "#111111",
            fill: %{amount: 75, direction: :to_top, color: "#00AA44"},
            text: %{content: "Volume", color: "#FFFFFF", font_size: 12, orientation: :vertical, valign: :middle}
          },
          %{
            background: "#111111",
            fill: %{amount: 40, direction: :to_top, color: "#CC6600"},
            text: %{content: "Bright", color: "#FFFFFF", font_size: 12, orientation: :vertical, valign: :middle}
          }
        ]

        for {strip, instructions} <- Enum.zip(strips, strip_labels) do
          pixels = Renderer.render_frame(instructions, strip)

          DeviceServer.render(id, %DrawBuffer{
            control_id: strip.id,
            x: 0,
            y: 0,
            width: strip.display.width,
            height: strip.display.height,
            pixels: pixels
          })
        end

        refresh_all_displays(id, spec)
        IO.puts("\n  Displaying vertical text on strips...")
        Process.sleep(2000)
        clear_all_displays(id, spec)
      end
    end
  end

  describe "LED rendering" do
    test "sets LED colors on all LED buttons", %{device_id: id, spec: spec} do
      led_controls = Spec.controls_with_capability(spec, :led)
      assert led_controls != [], "No LED controls found"

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
      led_controls = Spec.controls_with_capability(spec, :led)
      keys = square_keys(spec)

      if led_controls != [] and keys != [] do
        # Light up the target button
        target = hd(led_controls)
        DeviceServer.render(id, %SetLED{control_id: target.id, color: "#00FF00"})

        # Show prompt across display keys
        render_prompt(id, spec, keys, "Press", "the green", "button")

        assert_receive {:device_event, ^id, %PressEvent{action: :press}}, @input_timeout_ms

        # Show success, wait for release
        render_prompt(id, spec, keys, "Got it!", "release", "now")

        assert_receive {:device_event, ^id, %PressEvent{action: :release}}, @input_timeout_ms

        DeviceServer.render(id, %SetLED{control_id: target.id, color: "#000000"})
        clear_all_displays(id, spec)
      end
    end

    test "receives knob rotation events", %{device_id: id, spec: spec} do
      keys = square_keys(spec)

      if keys != [] do
        render_prompt(id, spec, keys, "Rotate", "any", "knob")

        assert_receive {:device_event, ^id, %RotateEvent{direction: dir}}, @input_timeout_ms

        render_prompt(id, spec, keys, "Got it!", "#{dir}", "")
        Process.sleep(500)
        clear_all_displays(id, spec)
      else
        assert_receive {:device_event, ^id, %RotateEvent{}}, @input_timeout_ms
      end
    end

    test "receives touch events", %{device_id: id, spec: spec} do
      keys = square_keys(spec)

      if keys != [] do
        # Highlight the target key
        target = hd(keys)
        render_to_key(id, target, %{
          background: "#0044AA",
          text: %{content: "Touch", color: "#FFFFFF", font_size: 18}
        })

        # Show prompt on remaining keys
        rest = Enum.drop(keys, 1) |> Enum.take(2)
        prompt_instructions = [
          %{background: "#1a1a2e", text: %{content: "Touch", color: "#AAAAAA", font_size: 16}},
          %{background: "#1a1a2e", text: %{content: "blue key", color: "#4488FF", font_size: 14}}
        ]

        for {key, instr} <- Enum.zip(rest, prompt_instructions) do
          render_to_key(id, key, instr)
        end

        refresh_all_displays(id, spec)

        assert_receive {:device_event, ^id, %TouchEvent{action: :start} = touch}, @input_timeout_ms

        # Show touch coordinates on the device
        render_prompt(id, spec, keys,
          "Touch!",
          "(#{touch.x},#{touch.y})",
          "#{inspect(touch.control_id)}"
        )
        Process.sleep(800)

        # Drain the touch end event
        receive do
          {:device_event, ^id, %TouchEvent{action: :end}} -> :ok
        after
          2000 -> :ok
        end

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

  defp square_keys(spec) do
    spec.controls
    |> Enum.filter(fn c ->
      Control.has_capabilities?(c, [:display]) and
        c.display.width == c.display.height
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp render_to_key(device_id, control, instructions) do
    pixels = Renderer.render_frame(instructions, control)

    DeviceServer.render(device_id, %DrawBuffer{
      control_id: control.id,
      x: 0,
      y: 0,
      width: control.display.width,
      height: control.display.height,
      pixels: pixels
    })
  end

  # Render a prompt message spread across the first few display keys.
  # Each word gets its own key for readability on small screens.
  defp render_prompt(device_id, spec, keys, word1, word2, word3) do
    words = [word1, word2, word3]

    colors = [
      %{bg: "#0a2e1a", fg: "#44FF88"},
      %{bg: "#1a1a2e", fg: "#88BBFF"},
      %{bg: "#2e1a0a", fg: "#FFAA44"}
    ]

    prompt_keys = Enum.take(keys, 3)

    for {key, {word, color}} <- Enum.zip(prompt_keys, Enum.zip(words, colors)) do
      instructions =
        if word == "" do
          %{background: "#000000"}
        else
          %{
            background: color.bg,
            text: %{content: word, color: color.fg, font_size: 16}
          }
        end

      render_to_key(device_id, key, instructions)
    end

    # Clear remaining keys
    for key <- Enum.drop(keys, 3) do
      render_to_key(device_id, key, %{background: "#000000"})
    end

    refresh_all_displays(device_id, spec)
  end
end
