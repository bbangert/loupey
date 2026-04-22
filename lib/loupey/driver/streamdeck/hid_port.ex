defmodule Loupey.Driver.Streamdeck.HidPort do
  @moduledoc """
  Thin behaviour over the subset of `lawik/hid` that the StreamDeck transport
  actually uses. Lets tests swap in a stub without needing real hardware.

  Naming note: `lawik/hid` uses `write/2` for Output reports and
  `write_report/2` for Feature reports (matching `hid_write` vs.
  `hid_send_feature_report` in hidapi). This behaviour renames them to
  `write_output_report/2` and `write_feature_report/2` so the StreamDeck
  driver's intent is unambiguous.
  """

  @type handle :: term()

  # `lawik/hid` doesn't export a proper typespec for `HID.DeviceInfo`, so
  # model it as a plain map here. Discovery consumers pattern-match on
  # specific keys (`:vendor_id`, `:product_id`, `:path`) — an opaque
  # type wouldn't help them anyway.
  @type device_info :: map()

  @callback enumerate() :: [device_info()]
  @callback open(path :: String.t()) :: {:ok, handle()} | {:error, term()}
  @callback close(handle()) :: :ok
  @callback read(handle(), size :: pos_integer()) :: {:ok, binary()} | {:error, term()}
  @callback write_output_report(handle(), binary()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback write_feature_report(handle(), binary()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
