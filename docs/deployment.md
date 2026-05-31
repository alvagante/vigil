# Deployment & release operations

Vigil ships as a self-contained Mix release (`vigil`) and as a container image
built from the [`Dockerfile`](../Dockerfile). This realises design §12.

## Building

```sh
# Local release (requires the toolchain in .tool-versions)
MIX_ENV=prod mix release vigil
_build/prod/rel/vigil/bin/vigil start

# Container image
docker build -t vigil:local .
```

The release explicitly enumerates every umbrella app (see `releases/0` in the
root `mix.exs`). This is required: `vigil_web` does not depend on the integration
apps, so a default umbrella release would compile but never boot them, leaving
the plugin catalog empty in production.

## Required runtime environment variables

Read at boot by [`config/runtime.exs`](../config/runtime.exs). In `prod` the
release **fails fast with a clear error** if a required variable is missing.

| Variable          | Required (prod) | Default     | Purpose                                                        |
| ----------------- | --------------- | ----------- | -------------------------------------------------------------- |
| `DATABASE_URL`    | **yes**         | —           | Ecto connection URL, e.g. `ecto://USER:PASS@HOST/DATABASE`.    |
| `SECRET_KEY_BASE` | **yes**         | —           | Signs/encrypts cookies. Generate with `mix phx.gen.secret`.   |
| `PHX_HOST`        | no              | `localhost` | Public hostname used for URL generation.                      |
| `PORT`            | no              | `4000`      | HTTP listen port.                                             |
| `POOL_SIZE`       | no              | `10`        | Ecto connection pool size.                                    |
| `ECTO_IPV6`       | no              | `false`     | Set `true`/`1` to connect to the database over IPv6.          |
| `PHX_SERVER`      | set by release  | —           | `bin/vigil start` sets this so the HTTP endpoint serves.      |

## Database migrations

Run migrations from the assembled release (no Mix at runtime):

```sh
bin/vigil eval "Vigil.Release.migrate()"
```

The container entrypoint runs this automatically before starting the server.

## Health endpoint

`GET /_health` returns `{"status":"ok","version":"<release version>"}` as JSON
without touching the database or LiveView. It backs the container `HEALTHCHECK`
and the CI smoke test against the released artefact.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on pushes to
`main`/`devel` and on every pull request:

1. **lint** — `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`.
2. **test** — `mix test` against a Postgres service.
3. **release-smoke** — builds the release **image**, runs it against Postgres,
   and asserts `/_health` reports the version and `/` renders the
   "no integrations" empty state — exercising the released artefact, not `mix run`.
