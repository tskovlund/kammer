# Multi-stage build producing a small Elixir release image (SPEC §14).
#
# Build:  docker build -t kammer .
# Run:    see docker-compose.yml

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.14
ARG DEBIAN_VERSION=bookworm-20260623

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"

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
COPY assets assets

# Compile before bundling assets: app.css imports the colocated CSS that
# the compiler extracts into _build (phoenix-colocated).
RUN mix compile
RUN mix assets.deploy

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
