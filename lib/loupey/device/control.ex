defmodule Loupey.Device.Control do
  @moduledoc """
  A single physical element on a device with one or more capabilities.

  Controls represent buttons, knobs, touch regions, display keys, sliders, etc.
  Each control has a set of capabilities describing what it can do — a knob might
  rotate and also be pressed, a touch key might accept touch input and also render
  pixels.

  ## Capabilities

  - `:press` — registers press/release events
  - `:rotate` — registers clockwise/counter-clockwise rotation
  - `:touch` — registers x/y multi-touch events (start/move/end with touch_id)
  - `:display` — can render pixels (has associated display properties)
  - `:led` — can be set to an RGB color
  - `:haptic` — can vibrate

  ## Examples

      # A knob that rotates and clicks
      %Control{id: :knob_tl, capabilities: MapSet.new([:rotate, :press])}

      # A touch display key
      %Control{
        id: {:key, 5},
        capabilities: MapSet.new([:touch, :display]),
        display: %Display{width: 90, height: 90, pixel_format: :rgb565}
      }

      # A colored button (LED, no display)
      %Control{id: {:button, 0}, capabilities: MapSet.new([:press, :led])}

  """

  alias Loupey.Device.Display

  @type capability :: :press | :rotate | :touch | :display | :led | :haptic
  @type id :: atom() | {atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          id: id(),
          capabilities: MapSet.t(capability()),
          display: Display.t() | nil
        }

  @enforce_keys [:id, :capabilities]
  defstruct [:id, :capabilities, :display]

  @doc """
  Returns true if the control has the given capability.
  """
  @spec has_capability?(t(), capability()) :: boolean()
  def has_capability?(%__MODULE__{capabilities: caps}, capability) do
    MapSet.member?(caps, capability)
  end

  @doc """
  Returns true if the control has all of the given capabilities.
  """
  @spec has_capabilities?(t(), [capability()]) :: boolean()
  def has_capabilities?(%__MODULE__{capabilities: caps}, required) do
    required
    |> MapSet.new()
    |> MapSet.subset?(caps)
  end
end
