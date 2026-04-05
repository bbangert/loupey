defmodule Loupey.HA.ServiceCall do
  @moduledoc """
  A request to call a Home Assistant service.

  Used by the binding engine to send commands to HA when a device
  input triggers an action.
  """

  @type t :: %__MODULE__{
          domain: String.t(),
          service: String.t(),
          target: map() | nil,
          service_data: map()
        }

  @enforce_keys [:domain, :service]
  defstruct [:domain, :service, :target, service_data: %{}]
end
