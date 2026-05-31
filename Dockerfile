# syntax=docker/dockerfile:1

# ---- Build stage ---------------------------------------------------------
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.0-debian-bookworm-20260518-slim
ARG RUNNER_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS build

# Build tooling. Tailwind/esbuild ship as standalone binaries (downloaded by
# the mix tasks), so no Node toolchain is required.
RUN apt-get update -y \
  && apt-get install -y build-essential git \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Fetch deps first for layer caching.
COPY mix.exs mix.lock ./
COPY apps/vigil_core/mix.exs apps/vigil_core/mix.exs
COPY apps/vigil_plugin/mix.exs apps/vigil_plugin/mix.exs
COPY apps/vigil_web/mix.exs apps/vigil_web/mix.exs
COPY apps/vigil_auth_oidc/mix.exs apps/vigil_auth_oidc/mix.exs
COPY apps/vigil_integrations_puppet/mix.exs apps/vigil_integrations_puppet/mix.exs
COPY apps/vigil_integrations_bolt/mix.exs apps/vigil_integrations_bolt/mix.exs
COPY apps/vigil_integrations_ansible/mix.exs apps/vigil_integrations_ansible/mix.exs
COPY apps/vigil_integrations_ssh/mix.exs apps/vigil_integrations_ssh/mix.exs
COPY apps/vigil_integrations_proxmox/mix.exs apps/vigil_integrations_proxmox/mix.exs
RUN mix deps.get --only prod

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Application source.
COPY apps apps
COPY config/runtime.exs config/
COPY rel rel

# Build digested, minified assets, then assemble the release.
RUN mix cmd --app vigil_web mix assets.setup \
  && mix cmd --app vigil_web mix assets.deploy
RUN mix compile
RUN mix release vigil

# ---- Runtime stage -------------------------------------------------------
FROM ${RUNNER_IMAGE} AS app

RUN apt-get update -y \
  && apt-get install -y ca-certificates libstdc++6 openssl libncurses6 locales curl \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Set UTF-8 locale for correct string handling.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as an unprivileged user.
RUN useradd --create-home app
COPY --from=build --chown=app:app /app/_build/prod/rel/vigil ./
USER app

ENV PHX_SERVER=true PORT=4000
EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:4000/_health || exit 1

# Run migrations, then start the release in the foreground.
CMD ["/bin/sh", "-c", "/app/bin/vigil eval 'Vigil.Release.migrate()' && exec /app/bin/vigil start"]
