defmodule Loupey.Device.Spec do
  @moduledoc """
  A complete description of a device's physical layout and capabilities.

  A DeviceSpec declares all the controls a device has, making it possible to
  write device-agnostic code that works with any hardware. The spec is provided
  by a device driver and used by the functional core for input parsing, command
  encoding, and touch target resolution.
  """

  alias Loupey.Device.Control

  @type t :: %__MODULE__{
          type: String.t(),
          controls: [Control.t()]
        }

  @enforce_keys [:type, :controls]
  defstruct [:type, :controls]

  @doc """
  Find a control by its id.
  """
  @spec find_control(t(), Control.id()) :: Control.t() | nil
  def find_control(%__MODULE__{controls: controls}, id) do
    Enum.find(controls, &(&1.id == id))
  end

  @doc """
  Find all controls that have the given capability.
  """
  @spec controls_with_capability(t(), Control.capability()) :: [Control.t()]
  def controls_with_capability(%__MODULE__{controls: controls}, capability) do
    Enum.filter(controls, &Control.has_capability?(&1, capability))
  end

  @doc """
  Find the control at the given x, y touch coordinate by checking display controls
  with the `:touch` capability.

  Returns `nil` if no touch-capable display contains the coordinate.
  """
  @spec resolve_touch(t(), non_neg_integer(), non_neg_integer()) :: Control.t() | nil
  def resolve_touch(%__MODULE__{controls: controls}, x, y) do
    controls
    |> Enum.filter(&Control.has_capabilities?(&1, [:touch, :display]))
    |> Enum.find(fn control ->
      display = control.display
      {ox, oy} = display.offset || {0, 0}
      x >= ox and x < ox + display.width and y >= oy and y < oy + display.height
    end)
  end
end
