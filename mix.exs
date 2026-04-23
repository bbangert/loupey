defmodule Loupey.MixProject do
  use Mix.Project

  def project do
    [
      app: :loupey,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps(),
      # Put the Dialyzer PLT files under `priv/plts` instead of the
      # default `_build/<env>/` location. Stable path = narrow cache key
      # in CI (see .github/workflows/ci.yml); the PLT is expensive to
      # build (~minutes) and cheap to load when cached.
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Loupey.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Device communication
      {:circuits_uart, "~> 1.5"},
      {:hid, github: "lawik/hid"},
      {:image, "~> 0.55.2"},

      # Home Assistant
      {:hassock, "~> 0.1.3"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:ymlr, "~> 5.0"},

      # Phoenix & web
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:plug_cowboy, "~> 2.7"},

      # Database
      {:ecto_sqlite3, "~> 0.17"},

      # Dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind loupey", "esbuild loupey"],
      "assets.deploy": [
        "tailwind loupey --minify",
        "esbuild loupey --minify",
        "phx.digest"
      ]
    ]
  end
end
