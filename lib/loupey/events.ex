defmodule Loupey.Events do
  @moduledoc """
  Normalized input events from device controls.

  All device drivers produce these same event types regardless of the underlying
  hardware protocol. Each event references a `control_id` from the device's spec.
  """

  defmodule PressEvent do
    @moduledoc "A press or release from any control with the `:press` capability."
    @type t :: %__MODULE__{
            control_id: Loupey.Device.Control.id(),
            action: :press | :release
          }
    @enforce_keys [:control_id, :action]
    defstruct [:control_id, :action]
  end

  defmodule RotateEvent do
    @moduledoc "A rotation from any control with the `:rotate` capability."
    @type t :: %__MODULE__{
            control_id: Loupey.Device.Control.id(),
            direction: :cw | :ccw
          }
    @enforce_keys [:control_id, :direction]
    defstruct [:control_id, :direction]
  end

  defmodule TouchEvent do
    @moduledoc "A touch event from any control with the `:touch` capability."
    @type t :: %__MODULE__{
            control_id: Loupey.Device.Control.id(),
            action: :start | :move | :end,
            x: non_neg_integer(),
            y: non_neg_integer(),
            touch_id: non_neg_integer()
          }
    @enforce_keys [:control_id, :action, :x, :y, :touch_id]
    defstruct [:control_id, :action, :x, :y, :touch_id]
  end

  @type t :: PressEvent.t() | RotateEvent.t() | TouchEvent.t()
end
