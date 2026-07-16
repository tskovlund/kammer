# Multi-stage build producing a small Elixir release image (SPEC §14).
#
# Build:  docker build -t kammer .
# Run:    see docker-compose.yml

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.14
ARG DEBIAN_VERSION=bookworm-20260623
ARG NODE_VERSION=22

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"

# ---------------------------------------------------------------------------
# Svelte PWA client (ADR 0024, issue #176/#187): built here, shipped inside
# the release at priv/static/app, served by the endpoint at the site root.
# The base path is baked into the client at build time (`paths.base` in
# clients/web/vite.config.ts) and must match :pwa_base_path in
# config/config.exs (now "/").

FROM node:${NODE_VERSION}-slim AS client

WORKDIR /client

# pnpm via corepack, pinned by the "packageManager" field in package.json.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

# Lockfile-only layer first so dependency installation is cached across
# source-only changes.
COPY clients/web/package.json clients/web/pnpm-lock.yaml \
     clients/web/pnpm-workspace.yaml clients/web/.npmrc ./
RUN pnpm install --frozen-lockfile

COPY clients/web/ ./
RUN pnpm build

# ---------------------------------------------------------------------------

FROM ${BUILDER_IMAGE} AS builder

# libvips (with HEIF support in Debian bookworm) is provided by the platform
# so image processing behaves identically in dev (Nix), CI, and the release.
ENV VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS

RUN apt-get update -y && \
    apt-get install -y build-essential git pkg-config libvips-dev && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config first so dependency compilation is cached.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

RUN mix compile

# Ship the built PWA inside the release. SvelteKit already content-hashes
# its own files (no phx.digest step remains — the LiveView asset pipeline
# is gone, #187). Lands in priv/static/app, which the endpoint serves at
# the site root — see :pwa_base_path in config/config.exs.
COPY --from=client /client/build ./priv/static/app

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---------------------------------------------------------------------------

FROM ${RUNNER_IMAGE}

ENV VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
      libvips42 poppler-utils && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV=prod

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/kammer ./

USER nobody

# Local-disk uploads live here by default; mount a volume in compose.
RUN mkdir -p /app/uploads
ENV UPLOADS_PATH=/app/uploads

EXPOSE 4000

CMD ["/app/bin/server"]
