import Config

config :loupey,
  ecto_repos: [Loupey.Repo]

config :loupey, Loupey.Repo,
  database: Path.expand("../loupey_#{config_env()}.db", __DIR__),
  pool_size: 5

config :loupey, LoupeyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: LoupeyWeb.ErrorHTML, json: LoupeyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Loupey.PubSub,
  live_view: [signing_salt: "loupey_lv_salt"]

config :esbuild,
  version: "0.17.11",
  loupey: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  loupey: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
