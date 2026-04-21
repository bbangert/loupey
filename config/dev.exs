import Config

config :loupey, LoupeyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:loupey, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:loupey, ~w(--watch)]}
  ]

config :loupey, LoupeyWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/loupey_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :loupey, dev_routes: true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
