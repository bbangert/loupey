defmodule Loupey.Bindings.Profile do
  @moduledoc """
  A complete device configuration containing named layouts.

  A profile holds all layouts for a device and tracks which layout is active.
  Layout switching is handled through `switch_layout` input rules — any control
  can trigger a layout switch.

  `:keyframes` holds named, profile-scoped keyframe definitions referenced
  by string name from individual rules' animation hooks.
  """

  alias Loupey.Animation.Keyframes
  alias Loupey.Bindings.Layout

  @type t :: %__MODULE__{
          name: String.t(),
          device_type: String.t(),
          layouts: %{String.t() => Layout.t()},
          active_layout: String.t(),
          keyframes: %{String.t() => Keyframes.t()}
        }

  @enforce_keys [:name, :device_type, :active_layout]
  defstruct [:name, :device_type, :active_layout, layouts: %{}, keyframes: %{}]
end
