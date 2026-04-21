defmodule Loupey.Driver.Streamdeck.HidTransport do
  @moduledoc """
  Per-device HID transport for the Stream Deck driver.

  Owns a single HID handle and a dedicated reader process that blocks on
  `HID.read/2` in a loop. Every successful read is forwarded to the parent
  pid as `{:device_data, bytes}` — the same shape `Loupey.DeviceServer`
  expects from any driver.

  ## Why a reader process

  `lawik/hid` exposes only the blocking form of `hid_read_timeout` (the NIF
  hardcodes `-1` and offers no non-blocking variant). A poll loop with a
  short timeout isn't possible, so we spawn a linked reader that lives in
  the blocking read. The read runs on a dirty scheduler (`ERL_NIF_DIRTY_`
  `JOB_IO_BOUND`), so it doesn't starve the VM.

  On shutdown, `terminate/2` calls `HidPort.close/1`; the hidraw backend
  surfaces the closed fd as an error from the pending `hid_read_timeout`,
  which returns as `{:error, _}` from `HID.read/2`, so the reader exits
  naturally.
  """

  use GenServer
  require Logger

  alias Loupey.Driver.Streamdeck.HidPort

  # MK.2 input reports are 19 bytes (4 header + 15 key states). Override
  # via the `:input_report_size` option for other devices.
  @default_input_report_size 19

  defmodule State do
    @moduledoc false
    defstruct [:handle, :port_mod, :parent, :reader, :input_report_size, :path]
  end

  # -- Public API --

  @doc """
  Start the transport. `opts` keys:

  - `:parent` (required) — pid that receives `{:device_data, binary}` messages.
  - `:port_mod` — `HidPort` implementation (defaults to `HidPort.Real`).
  - `:input_report_size` — bytes per read (defaults to `#{@default_input_report_size}`).
  """
  @spec start_link(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(path, opts) when is_binary(path) do
    GenServer.start_link(__MODULE__, {path, opts})
  end

  @doc "Close the transport and release the HID handle."
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.stop(pid, :normal)

  @doc "Write an Output report (most packets — key images, reset, etc.)."
  @spec write_output(pid(), binary()) :: :ok | {:error, term()}
  def write_output(pid, data) when is_binary(data) do
    GenServer.call(pid, {:write_output, data}, 5_000)
  end

  @doc "Write a Feature report (brightness, firmware queries, etc.)."
  @spec write_feature(pid(), binary()) :: :ok | {:error, term()}
  def write_feature(pid, data) when is_binary(data) do
    GenServer.call(pid, {:write_feature, data}, 5_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init({path, opts}) do
    parent = Keyword.fetch!(opts, :parent)
    port_mod = Keyword.get(opts, :port_mod, HidPort.Real)
    size = Keyword.get(opts, :input_report_size, @default_input_report_size)

    Process.flag(:trap_exit, true)

    case port_mod.open(path) do
      {:ok, handle} ->
        reader = spawn_reader(handle, port_mod, size)

        state = %State{
          handle: handle,
          port_mod: port_mod,
          parent: parent,
          reader: reader,
          input_report_size: size,
          path: path
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:hid_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:write_output, data}, _from, state) do
    {:reply, normalize_write(state.port_mod.write_output_report(state.handle, data)), state}
  end

  def handle_call({:write_feature, data}, _from, state) do
    {:reply, normalize_write(state.port_mod.write_feature_report(state.handle, data)), state}
  end

  @impl true
  def handle_info({:hid_data, bytes}, state) do
    send(state.parent, {:device_data, bytes})
    {:noreply, state}
  end

  # The reader gave up — its blocking read returned an error or it crashed.
  # Either way, our handle is unusable; stop so the DeviceServer supervisor
  # restarts us fresh.
  def handle_info({:EXIT, reader, reason}, %State{reader: reader} = state) do
    Logger.warning("HID reader exited on #{state.path}: #{inspect(reason)}")
    {:stop, {:reader_exited, reason}, %{state | reader: nil}}
  end

  # Parent DeviceServer crashed — no one left to serve.
  def handle_info({:EXIT, parent, reason}, %State{parent: parent} = state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the handle unblocks the reader if it's still pending on read.
    try do
      if state.handle, do: state.port_mod.close(state.handle)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # -- Internals --

  # hidapi's write* functions return {:ok, bytes_written} on success.
  # The DeviceServer contract is `:ok | {:error, reason}`.
  defp normalize_write({:ok, _bytes}), do: :ok
  defp normalize_write({:error, _} = err), do: err

  defp spawn_reader(handle, port_mod, size) do
    owner = self()
    spawn_link(fn -> reader_loop(handle, port_mod, owner, size) end)
  end

  defp reader_loop(handle, port_mod, owner, size) do
    case port_mod.read(handle, size) do
      # HID.read returns {:ok, ""} if it returned 0 bytes — just loop.
      {:ok, ""} ->
        reader_loop(handle, port_mod, owner, size)

      {:ok, bytes} ->
        send(owner, {:hid_data, bytes})
        reader_loop(handle, port_mod, owner, size)

      {:error, reason} ->
        # Handle closed from under us (normal shutdown) or a real read error.
        # Either way we're done; let the EXIT reach the owner.
        exit({:shutdown, reason})
    end
  end
end
