defmodule Loupey.Bindings.Layout do
  @moduledoc """
  A named configuration that defines what every control on the device does and shows.

  Layouts are the core organizational unit — each layout maps control IDs to
  lists of bindings. A control can have multiple bindings (one per capability),
  e.g., a knob with a `:rotate` binding for volume and a `:press` binding for mute.
  """

  alias Loupey.Bindings.Binding
  alias Loupey.Device.Control

  @type t :: %__MODULE__{
          name: String.t(),
          bindings: %{Control.id() => [Binding.t()]}
        }

  @enforce_keys [:name]
  defstruct [:name, bindings: %{}]
end
