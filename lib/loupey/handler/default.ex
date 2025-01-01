defmodule Loupey.Handler.Default do
  use GenServer
  require Logger

  defmodule State do
    defstruct [:handler_pid]
  end

  def start_link(handler_pid) do
    GenServer.start_link(__MODULE__, handler_pid)
  end

  def init(handler_pid) do
    {:ok, %State{handler_pid: handler_pid}}
  end

  @spec handle_message(pid(), Loupey.Device.command()) :: any()
  def handle_message(pid, command) do
    GenServer.cast(pid, command)
  end

  def handle_cast(_, state) do
    {:noreply, state}
  end
end
