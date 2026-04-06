defmodule LoupeyWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.
  """
  use Phoenix.Component

  @doc """
  Renders flash notices.
  """
  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], required: true

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      class={[
        "rounded-lg p-3 text-sm mb-4",
        @kind == :info && "bg-emerald-900 text-emerald-200",
        @kind == :error && "bg-rose-900 text-rose-200"
      ]}
    >
      {msg}
    </div>
    """
  end

  @doc """
  Shows flash messages for info and error.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <.flash flash={@flash} kind={:info} />
    <.flash flash={@flash} kind={:error} />
    """
  end
end
