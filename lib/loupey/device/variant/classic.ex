defmodule Loupey.Device.Variant.Classic do
  @moduledoc """
  Variant configuration for the Elgato Stream Deck "Classic" family — the
  four devices that share one HID command set and the 5×3 72 px key layout:

  | Device                          | PID      |
  |---------------------------------|----------|
  | Stream Deck MK.2                | `0x0080` |
  | Stream Deck MK.2 (Scissor Keys) | `0x00A5` |
  | Stream Deck 2019                | `0x006D` |
  | Stream Deck 15-Key Module       | `0x00B9` |

  Source: <https://docs.elgato.com/streamdeck/hid/stream-deck-classic>.

  The MK.1 (`0x0060`) is explicitly NOT part of this family — it uses a
  different command set and is out of scope here.

  `device_spec/0` reports `type: "Stream Deck (Classic)"` — a family label
  rather than a specific model, since all four PIDs above share this spec.

  Physical layout:
  ```
  ┌──────────────────────────────┐
  │  5×3 grid of 72×72 px keys   │
  │  (JPEG, written per-key)     │
  └──────────────────────────────┘
  ```
  """

  @behaviour Loupey.Device.Variant

  alias Loupey.Device.{Control, Display, Spec}

  @vendor_id 0x0FD9
  @product_ids [0x0080, 0x00A5, 0x006D, 0x00B9]
  @key_size 72
  @columns 5
  @rows 3

  @doc "The four product IDs that share this command set."
  @spec product_ids() :: [non_neg_integer()]
  def product_ids, do: @product_ids

  @doc "Elgato's USB vendor ID."
  @spec vendor_id() :: non_neg_integer()
  def vendor_id, do: @vendor_id

  @impl true
  def is_variant?(%{vendor_id: @vendor_id, product_id: pid}), do: pid in @product_ids
  def is_variant?(_), do: false

  @impl true
  def device_spec do
    %Spec{
      type: "Stream Deck (Classic)",
      controls: key_controls()
    }
  end

  # -- Control definitions --

  defp key_controls do
    for row <- 0..(@rows - 1), col <- 0..(@columns - 1) do
      key = row * @columns + col

      %Control{
        id: {:key, key},
        capabilities: MapSet.new([:press, :display]),
        display: %Display{
          width: @key_size,
          height: @key_size,
          pixel_format: :jpeg_flipped,
          offset: {col * @key_size, row * @key_size},
          display_id: nil
        }
      }
    end
  end
end
