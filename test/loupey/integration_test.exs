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
  6. Runs all six built-in animation effects in parallel on separate keys
     and waits for a press on a designated ack target
  7. Waits for user input events (button press, knob rotate, touch)

  The test renders a visible sequence so you can visually verify output,
  then prompts you to interact with the device to verify input.
  """

  use ExUnit.Case

  alias Loupey.Animation
  alias Loupey.Animation.{Effects, Ticker}
  alias Loupey.Device.{Control, Spec}
  alias Loupey.Devices
  alias Loupey.DeviceServer
  alias Loupey.Events.{PressEvent, RotateEvent, TouchEvent}
  alias Loupey.Graphics.{IconCache, Renderer}
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

    test "renders icons from icons/ directory across display keys in pages", %{
      device_id: id,
      spec: spec
    } do
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

        IO.puts(
          "\n  Rendering #{length(icon_paths)} icons across #{total_pages} pages of #{key_count} keys..."
        )

        backgrounds =
          Stream.cycle(["#1a1a2e", "#16213e", "#0f3460", "#1a0a2e", "#2e1a0a", "#0a2e1a"])

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
        %{
          text: %{content: "TOP", color: "#FFAA00", font_size: 14, valign: :top},
          background: "#1a1a1a"
        },
        %{
          text: %{content: "BTM", color: "#FFAA00", font_size: 14, valign: :bottom},
          background: "#1a1a1a"
        },
        %{
          text: %{content: "LEFT", color: "#00AAFF", font_size: 12, align: :left},
          background: "#1a1a1a"
        },
        %{
          text: %{content: "RIGHT", color: "#00AAFF", font_size: 12, align: :right},
          background: "#1a1a1a"
        },
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
            text: %{
              content: "Volume",
              color: "#FFFFFF",
              font_size: 12,
              orientation: :vertical,
              valign: :middle
            }
          },
          %{
            background: "#111111",
            fill: %{amount: 40, direction: :to_top, color: "#CC6600"},
            text: %{
              content: "Bright",
              color: "#FFFFFF",
              font_size: 12,
              orientation: :vertical,
              valign: :middle
            }
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

      colors = [
        "#FF0000",
        "#00FF00",
        "#0000FF",
        "#FFFF00",
        "#FF00FF",
        "#00FFFF",
        "#FFFFFF",
        "#FF8800"
      ]

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

  describe "animation effects (parallel demo)" do
    test "renders all built-in effects on separate keys, ack via press", %{
      device_id: id,
      spec: spec
    } do
      keys = square_keys(spec)
      led_controls = Spec.controls_with_capability(spec, :led)

      effects = [
        {"PULSE",
         Effects.pulse(%{
           color: "#FFD700",
           iterations: :infinite,
           direction: :alternate,
           duration_ms: 1000,
           intensity: 110
         })},
        {"FLASH",
         Effects.flash(%{
           color: "#FF4444",
           iterations: :infinite,
           direction: :alternate,
           duration_ms: 500,
           intensity: 200
         })},
        {"SHAKE",
         Effects.shake(%{
           amplitude: 5,
           iterations: :infinite,
           duration_ms: 600
         })},
        {"WIGGLE",
         Effects.wiggle(%{
           angle: 12,
           iterations: :infinite,
           duration_ms: 600
         })},
        {"SQUISH",
         Effects.squish(%{
           min_scale: 0.85,
           iterations: :infinite,
           duration_ms: 700
         })},
        {"RIPPLE",
         Effects.ripple(%{
           color: "#88FF88",
           iterations: :infinite,
           direction: :alternate,
           duration_ms: 700,
           intensity: 140
         })}
      ]

      if length(keys) < length(effects) do
        IO.puts(
          "  Need #{length(effects)} display keys for parallel effects demo, got #{length(keys)} — skipping"
        )
      else
        {:ok, _ticker_pid} = Animation.start_ticker(device_id: id, spec: spec)

        # `shake`, `wiggle`, and `squish` operate on `target: :icon` —
        # without an icon in the base instructions, `apply_icon` is a
        # no-op and the transform never fires (silently invisible).
        # Load a stable icon for every effect key so all six render
        # something the user can see being manipulated.
        #
        # CRITICAL: must materialize via `IconCache.lookup/2` (which
        # calls `Vix.Vips.Image.copy_memory/1`). A bare
        # `Image.thumbnail!/2` returns a LAZY image — reusing it across
        # multiple composites trips `pngload: out of order read` and
        # crashes the Ticker after the first frame.
        icon_path =
          Enum.find(
            [
              "icons/neon_blue/Audio_On.png",
              "icons/neon_blue/Alerts.png"
            ],
            &File.exists?/1
          )

        icon =
          if icon_path do
            max_dim = round(min(hd(keys).display.width, hd(keys).display.height) * 0.55)
            {:ok, img} = IconCache.lookup(icon_path, max_dim)
            img
          end

        # Pair each effect with a key. Use a contrasting base render per
        # key so the animation has something visible to layer over.
        base_for = fn label ->
          %{
            background: "#1a1a2e",
            icon: icon,
            text: %{
              content: label,
              color: "#CCCCCC",
              font_size: 14,
              valign: :bottom
            }
          }
        end

        effect_keys = Enum.zip(Enum.take(keys, length(effects)), effects)

        for {key, {label, kf}} <- effect_keys do
          base = base_for.(label)
          # Pre-render the base so the key shows the label even before the
          # first tick lands a frame.
          render_to_key(id, key, base)
          :ok = Ticker.start_animation(id, key.id, :continuous, kf, base)
        end

        refresh_all_displays(id, spec)

        # Ack target: prefer a physical LED+press button (Loupedeck style),
        # else the first remaining display key (Stream Deck style).
        {ack_kind, ack_id, ack_cleanup} = pick_ack_target(id, keys, effect_keys, led_controls)

        IO.puts(
          "\n  Verify all 6 effects are animating in parallel.\n" <>
            "  Press the GREEN ack target (#{ack_kind}) to confirm — #{@input_timeout_ms}ms timeout."
        )

        # Accept either a physical press OR a touch_start. Different device
        # families surface "press" differently; either is a valid ack.
        ack =
          receive do
            {:device_event, ^id, %PressEvent{control_id: ^ack_id, action: :press}} -> :press
            {:device_event, ^id, %TouchEvent{control_id: ^ack_id, action: :start}} -> :touch
          after
            @input_timeout_ms ->
              flunk(
                "no acknowledgment received within #{@input_timeout_ms}ms — " <>
                  "did the effects animate visibly on the device?"
              )
          end

        assert ack in [:press, :touch]

        for {key, _} <- effect_keys do
          :ok = Ticker.cancel_all(id, key.id)
        end

        ack_cleanup.()
        Animation.stop_ticker(id)
        clear_all_displays(id, spec)
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

        assert_receive {:device_event, ^id, %TouchEvent{action: :start} = touch},
                       @input_timeout_ms

        # Show touch coordinates on the device
        render_prompt(
          id,
          spec,
          keys,
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

  # Picks an acknowledgment target: a press-capable LED button if the device
  # has one (Loupedeck), otherwise the first remaining unused display key
  # (Stream Deck). Returns `{kind, control_id, cleanup_fn}`.
  defp pick_ack_target(device_id, all_keys, used_effect_keys, [%Control{} = led | _]) do
    DeviceServer.render(device_id, %SetLED{control_id: led.id, color: "#00FF00"})

    cleanup = fn ->
      DeviceServer.render(device_id, %SetLED{control_id: led.id, color: "#000000"})
    end

    _ = used_effect_keys
    _ = all_keys
    {:led_button, led.id, cleanup}
  end

  defp pick_ack_target(device_id, all_keys, used_effect_keys, []) do
    used_ids = MapSet.new(used_effect_keys, fn {key, _} -> key.id end)
    spare = Enum.find(all_keys, fn k -> not MapSet.member?(used_ids, k.id) end)
    pick_display_ack(device_id, spare, used_effect_keys)
  end

  defp pick_display_ack(_device_id, nil, used_effect_keys) do
    # No spare key — overlay ack on the last effect key (rare path).
    last = List.last(used_effect_keys) |> elem(0)
    {:overlay_key, last.id, fn -> :ok end}
  end

  defp pick_display_ack(device_id, key, _used_effect_keys) do
    render_to_key(device_id, key, %{
      background: "#005500",
      text: %{content: "OK?", color: "#FFFFFF", font_size: 24}
    })

    {:display_key, key.id, fn -> :ok end}
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
