defmodule Vigil.Repo do
  use Ecto.Repo,
    otp_app: :vigil_core,
    adapter: Ecto.Adapters.Postgres
end
