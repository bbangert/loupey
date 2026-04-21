defmodule Loupey.Driver.Streamdeck do
  @moduledoc """
  Driver for the Elgato Stream Deck "Classic" family (MK.2, Scissor Keys,
  2019, 15-Key Module — see `Loupey.Device.Variant.Classic`).

  Wraps `Loupey.Driver.Streamdeck.HidTransport` as the transport and
  implements the Classic HID command set:

  - **Input**: 19-byte reports starting with `0x01` carry 15 key states at
    offset 4. `parse/2` diffs against the previous state to emit
    `%PressEvent{}` on edges only.
  - **Output (key images)**: JPEG bytes get chunked into 1024-byte packets
    (`0x02 0x07 …`), one per key image. Returned from `encode/1` as
    `{:image_packets, packets}` and shipped by `send_command/2` through
    `HidTransport.write_output/2`.
  - **Feature (brightness)**: a 32-byte padded feature report
    `<<0x03, 0x08, percent, 0::padding>>`. Returned as
    `{:feature_report, bytes}` and shipped via `HidTransport.write_feature/2`.
  - **LEDs**: unsupported — the Classic family has no per-key LEDs distinct
    from the LCD. `encode/1` returns `:unsupported` and `send_command/2`
    treats it as a no-op.

  Protocol reference:
  <https://docs.elgato.com/streamdeck/hid/stream-deck-classic>.
  """

  @behaviour Loupey.Driver

  alias Loupey.Device.Variant.Classic
  alias Loupey.Driver.Streamdeck.HidTransport
  alias Loupey.Events.PressEvent
  alias Loupey.RenderCommands.{DrawBuffer, SetBrightness, SetLED}

  @input_report_id 0x01
  @image_report_id 0x02
  @image_command 0x07
  @brightness_report_id 0x03
  @brightness_command 0x08

  @packet_size 1024
  @packet_header_size 8
  @packet_payload_size @packet_size - @packet_header_size

  @feature_report_size 32

  @key_count 15

  defmodule DriverState do
    @moduledoc false
    defstruct keys: <<0::size(15)-unit(8)>>
  end

  @impl true
  def device_spec, do: Classic.device_spec()

  @impl true
  def matches?(info), do: Classic.is_variant?(info)

  @impl true
  def open(path, opts), do: HidTransport.start_link(path, opts)

  @impl true
  def close(pid), do: HidTransport.close(pid)

  @doc "Initial driver state for `Loupey.DeviceServer.init/1`."
  def new_driver_state, do: %DriverState{}

  @impl true
  def parse(
        %DriverState{keys: prev} = state,
        <<@input_report_id, _cmd, _count::16, keys::binary-size(@key_count), _rest::binary>>
      ) do
    events = diff_keys(prev, keys)
    {%{state | keys: keys}, events}
  end

  def parse(state, _), do: {state, []}

  @impl true
  def encode(%DrawBuffer{control_id: {:key, n}, pixels: jpeg})
      when is_integer(n) and n >= 0 and n < @key_count and is_binary(jpeg) and byte_size(jpeg) > 0 do
    {:image_packets, build_image_packets(n, jpeg)}
  end

  def encode(%SetBrightness{level: level}) do
    percent = level |> clamp_unit() |> Kernel.*(100) |> round()
    body = <<@brightness_report_id, @brightness_command, percent>>
    {:feature_report, pad_feature_report(body)}
  end

  def encode(%SetLED{}), do: :unsupported

  @impl true
  def send_command(_pid, :unsupported), do: :ok

  def send_command(pid, {:feature_report, bytes}) do
    HidTransport.write_feature(pid, bytes)
  end

  def send_command(pid, {:image_packets, packets}) do
    Enum.reduce_while(packets, :ok, fn packet, _ ->
      case HidTransport.write_output(pid, packet) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp diff_keys(prev, curr) do
    for n <- 0..(@key_count - 1),
        (p = :binary.at(prev, n)) != (c = :binary.at(curr, n)),
        do: press_event(n, p, c)
  end

  defp press_event(n, 0, c) when c > 0, do: %PressEvent{control_id: {:key, n}, action: :press}
  defp press_event(n, _, 0), do: %PressEvent{control_id: {:key, n}, action: :release}

  defp clamp_unit(x) when is_number(x) and x <= 0, do: 0.0
  defp clamp_unit(x) when is_number(x) and x >= 1, do: 1.0
  defp clamp_unit(x) when is_number(x), do: x * 1.0

  defp pad_feature_report(bytes) when byte_size(bytes) >= @feature_report_size, do: bytes

  defp pad_feature_report(bytes) do
    pad = @feature_report_size - byte_size(bytes)
    bytes <> :binary.copy(<<0>>, pad)
  end

  defp build_image_packets(key_idx, jpeg) do
    total = byte_size(jpeg)
    chunk_count = div(total + @packet_payload_size - 1, @packet_payload_size)

    for page <- 0..(chunk_count - 1) do
      offset = page * @packet_payload_size
      chunk_size = min(@packet_payload_size, total - offset)
      done = if page == chunk_count - 1, do: 0x01, else: 0x00
      chunk = :binary.part(jpeg, offset, chunk_size)
      padding = :binary.copy(<<0>>, @packet_payload_size - chunk_size)

      <<@image_report_id, @image_command, key_idx, done, chunk_size::little-16, page::little-16,
        chunk::binary, padding::binary>>
    end
  end
end
