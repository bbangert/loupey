defmodule Loupey.Icons do
  @moduledoc """
  Scans the project's `icons/` directory for image files.
  """

  @icons_dir Path.join(File.cwd!(), "icons")

  @doc """
  Returns a sorted list of icon maps found under the icons directory.

  Each map contains:
  - `:name` — filename without extension
  - `:path` — path prefixed with `icons/` (for storage in bindings)
  - `:relative` — path relative to the icons directory (for URL construction)
  """
  @spec scan() :: [%{name: String.t(), path: String.t(), relative: String.t()}]
  def scan do
    if File.dir?(@icons_dir) do
      @icons_dir
      |> scan_dir_recursive("")
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end

  defp scan_dir_recursive(base_dir, relative_prefix) do
    dir = if relative_prefix == "", do: base_dir, else: Path.join(base_dir, relative_prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, &classify_entry(base_dir, relative_prefix, &1))

      _ ->
        []
    end
  end

  defp classify_entry(base_dir, prefix, entry) do
    relative = build_relative_path(prefix, entry)
    full_path = Path.join(base_dir, relative)

    cond do
      File.dir?(full_path) ->
        scan_dir_recursive(base_dir, relative)

      image_file?(entry) ->
        [%{name: Path.rootname(entry), path: Path.join("icons", relative), relative: relative}]

      true ->
        []
    end
  end

  defp build_relative_path("", entry), do: entry
  defp build_relative_path(prefix, entry), do: Path.join(prefix, entry)

  defp image_file?(entry), do: String.match?(entry, ~r/\.(png|jpg|jpeg|svg|gif)$/i)
end
