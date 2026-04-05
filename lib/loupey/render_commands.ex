defmodule Loupey.RenderCommands do
  @moduledoc """
  Normalized output commands sent to device controls.

  These are device-agnostic render instructions that the device driver encodes
  into the hardware-specific protocol.
  """

  defmodule DrawBuffer do
    @moduledoc "Draw pixels to a control with the `:display` capability."
    @type t :: %__MODULE__{
            control_id: Loupey.Device.Control.id(),
            x: non_neg_integer(),
            y: non_neg_integer(),
            width: pos_integer(),
            height: pos_integer(),
            pixels: binary()
          }
    @enforce_keys [:control_id, :x, :y, :width, :height, :pixels]
    defstruct [:control_id, :x, :y, :width, :height, :pixels]
  end

  defmodule SetLED do
    @moduledoc "Set the color of a control with the `:led` capability."
    @type t :: %__MODULE__{
            control_id: Loupey.Device.Control.id(),
            color: String.t()
          }
    @enforce_keys [:control_id, :color]
    defstruct [:control_id, :color]
  end

  defmodule SetBrightness do
    @moduledoc "Set the device-wide display brightness."
    @type t :: %__MODULE__{
            level: float()
          }
    @enforce_keys [:level]
    defstruct [:level]
  end

  @type t :: DrawBuffer.t() | SetLED.t() | SetBrightness.t()
end
