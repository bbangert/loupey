import Config

config :loupey, Loupey.Repo,
  database: Path.expand("../loupey_test.db", __DIR__),
  pool_size: 5

config :loupey, LoupeyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept-it",
  server: false

config :logger, level: :warning
