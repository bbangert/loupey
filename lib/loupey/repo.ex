defmodule Loupey.Repo do
  use Ecto.Repo,
    otp_app: :loupey,
    adapter: Ecto.Adapters.SQLite3
end
