defmodule Loupey.Graphics.IconCache do
  @moduledoc """
  ETS-backed cache of pre-thumbnailed, memory-materialized icon images.

  ## Why this exists

  `Image.thumbnail!/2` returns a *lazy* libvips image — re-using the
  same lazy image across many composites trips
  `pngload: out of order read` because the underlying decoder gets
  re-driven concurrently. The animation tick loop composes icons
  many times per second, so every cached image must be fully
  materialized into memory via `Vix.Vips.Image.copy_memory/1`.

  The cache key is `{path, max_dim}` because the same icon can be
  requested at multiple sizes for different controls.

  ## Lifecycle

  An owning GenServer is started by `Loupey.Application` at boot. It
  owns the table so the table outlives transient lookup processes; it
  has no other state. Tests call `clear/0` to reset between cases.
  """

  use GenServer

  @table :loupey_icon_cache

  ## Public API

  @doc """
  Start the cache owner process. Called from `Loupey.Application`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Look up a thumbnailed icon by `{path, max_dim}`. Falls back to
  loading and materializing the image on a cache miss; subsequent
  lookups for the same key are O(1) ETS reads.

  Missing or unreadable files return `:error`.
  """
  @spec lookup(String.t(), pos_integer()) :: {:ok, Vix.Vips.Image.t()} | :error
  def lookup(path, max_dim) when is_binary(path) and is_integer(max_dim) and max_dim > 0 do
    key = {path, max_dim}

    case :ets.lookup(@table, key) do
      [{^key, image}] ->
        {:ok, image}

      [] ->
        load_and_store(key)
    end
  end

  @doc """
  Drop all cached entries. Used by tests and on profile reload to
  invalidate stale icon paths.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  ## GenServer callbacks

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  ## Internals

  defp load_and_store({path, max_dim} = key) do
    with {:ok, lazy} <- safe_thumbnail(path, max_dim),
         {:ok, materialized} <- Vix.Vips.Image.copy_memory(lazy) do
      :ets.insert(@table, {key, materialized})
      {:ok, materialized}
    else
      _ -> :error
    end
  end

  defp safe_thumbnail(path, max_dim) do
    {:ok, Image.thumbnail!(path, max_dim)}
  rescue
    _ -> :error
  end
end
