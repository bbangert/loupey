defmodule Loupey.Graphics.IconCacheTest do
  use ExUnit.Case, async: false

  alias Loupey.Graphics.IconCache

  @icon_path Path.expand("icons/neon_blue/Audio_On.png", File.cwd!())

  setup do
    IconCache.clear()
    on_exit(&IconCache.clear/0)
    :ok
  end

  describe "lookup/2" do
    test "loads, materializes, and caches an icon" do
      assert {:ok, img1} = IconCache.lookup(@icon_path, 64)
      assert {:ok, img2} = IconCache.lookup(@icon_path, 64)
      assert img1 == img2
      assert Image.width(img1) > 0
    end

    test "different sizes are cached separately" do
      {:ok, small} = IconCache.lookup(@icon_path, 32)
      {:ok, big} = IconCache.lookup(@icon_path, 96)
      assert Image.width(small) <= 32
      assert Image.width(big) <= 96
      assert Image.width(small) < Image.width(big)
    end

    test "missing files return :error" do
      assert IconCache.lookup("does/not/exist.png", 64) == :error
    end

    test "concurrent lookups for the same key all succeed without decoder races" do
      tasks =
        for _ <- 1..8 do
          Task.async(fn -> IconCache.lookup(@icon_path, 48) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      # After the race settles, subsequent lookups all hit the same cached entry.
      {:ok, cached} = IconCache.lookup(@icon_path, 48)
      {:ok, cached2} = IconCache.lookup(@icon_path, 48)
      assert cached == cached2
    end

    test "repeated composite of cached icon does not raise pngload errors" do
      {:ok, icon} = IconCache.lookup(@icon_path, 64)
      bg = Image.new!(72, 72, color: "#000000")

      Enum.each(1..100, fn _ ->
        composed = Image.compose!(bg, icon, x: 4, y: 4)
        flat = Image.flatten!(composed)
        # Force pixel materialization to surface any decoder reuse bugs.
        _ = Image.shape(flat)
      end)
    end
  end

  describe "clear/0" do
    test "drops all cached entries" do
      {:ok, _} = IconCache.lookup(@icon_path, 32)
      assert :ets.info(:loupey_icon_cache, :size) >= 1
      IconCache.clear()
      assert :ets.info(:loupey_icon_cache, :size) == 0
    end
  end
end
