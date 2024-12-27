defmodule Loupey.Handler.Default do
  use GenServer

  defmodule State do
    defstruct [:device]
  end

  def start_link(device) do
    GenServer.start_link(__MODULE__, device)
  end

  def init(device) do
    {:ok, %State{device: device}}
  end

  def handle_message(_command) do
  end
end
