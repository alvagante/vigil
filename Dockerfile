FROM hexpm/elixir:1.19.5-erlang-28.0-alpine-3.22.4 AS build

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY apps/vigil_auth_oidc/mix.exs ./apps/vigil_auth_oidc/
COPY apps/vigil_core/mix.exs ./apps/vigil_core/
COPY apps/vigil_integrations_ansible/mix.exs ./apps/vigil_integrations_ansible/
COPY apps/vigil_integrations_bolt/mix.exs ./apps/vigil_integrations_bolt/
COPY apps/vigil_integrations_proxmox/mix.exs ./apps/vigil_integrations_proxmox/
COPY apps/vigil_integrations_puppet/mix.exs ./apps/vigil_integrations_puppet/
COPY apps/vigil_integrations_ssh/mix.exs ./apps/vigil_integrations_ssh/
COPY apps/vigil_plugin/mix.exs ./apps/vigil_plugin/
COPY apps/vigil_web/mix.exs ./apps/vigil_web/

RUN mix deps.get --only prod

COPY . .

RUN mix deps.compile
RUN mix assets.deploy
RUN mix release

FROM alpine:3.22 AS runtime

RUN apk add --no-cache openssl ncurses libstdc++ libgcc bash openssh-client

WORKDIR /app
COPY --from=build /app/_build/prod/rel/vigil ./

ENV LANG=C.UTF-8
USER nobody
EXPOSE 4000
CMD ["bin/vigil", "start"]
