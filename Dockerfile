# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
#
# Builds the production release and runs it unprivileged against external PostgreSQL.
# DATABASE_URL and MEMHOUSE_AUTH_SIGNING_SECRET are required at runtime; builds consume
# no secrets. Keep build and runtime images on the same pinned Debian release.

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250428-slim
ARG DEBIAN_IMAGE=debian:bookworm-20250428-slim
ARG RUST_IMAGE=rust:1.85-slim-bookworm

# Rust is build-only and independently pinned for native extensions.
FROM ${RUST_IMAGE} AS rust-toolchain

FROM ${ELIXIR_IMAGE} AS build

COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup

# Build-only packages. They stay in this stage and never reach the runtime image.
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# Excludes development and test dependencies from the release.
ENV MIX_ENV=prod
# Download timeouts are milliseconds for Mix and seconds for Hex/Cargo. Serial Hex
# downloads reduce rate-limit failures on shared runners.
ENV MIX_HTTP_TIMEOUT=120000
ENV HEX_HTTP_TIMEOUT=120
ENV HEX_HTTP_CONCURRENCY=1
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:${PATH}
ENV CARGO_HTTP_TIMEOUT=120
ENV CARGO_NET_RETRY=5

# Hex and Rebar bootstrap retry three times because the commands have no retry option.
RUN (mix local.hex --force \
      || mix local.hex --force \
      || mix local.hex --force) \
    && (mix local.rebar --force \
      || mix local.rebar --force \
      || mix local.rebar --force)
# Keep dependency layers cacheable across source-only changes.
COPY mix.exs mix.lock ./
# BuildKit caches downloads without adding them to the image.
RUN --mount=type=cache,target=/root/.cache/rustler_precompiled \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    mix deps.get --only prod && mix deps.compile

# Campaign artifacts opt in to one immutable source revision. Ordinary images keep the
# fail-closed value that cannot activate campaign spend.
ARG MEMHOUSE_CAMPAIGN_BUILD_SHA=unknown
ENV MEMHOUSE_CAMPAIGN_BUILD_SHA=${MEMHOUSE_CAMPAIGN_BUILD_SHA}

# `rel` supplies the packaged server and migration launchers.
COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
RUN mix compile && mix release

# The release bundles Erlang, so the runtime image needs no compiler toolchain.
FROM ${DEBIAN_IMAGE} AS runtime

# Fixed uid 10001 supports bind mounts; the process never needs root at runtime.
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends libstdc++6 openssl libncurses6 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 memhouse \
    && mkdir -p /var/lib/memhouse/blobs \
    && chown -R memhouse:memhouse /var/lib/memhouse

WORKDIR /app
COPY --from=build --chown=memhouse:memhouse /build/_build/prod/rel/memhouse ./

# Erlang needs a writable HOME for cookies and caches.
USER memhouse
ENV HOME=/home/memhouse
# Starts the Phoenix endpoint.
ENV PHX_SERVER=true
# Containers always use operator-run PostgreSQL.
ENV MEMHOUSE_DATABASE_MODE=external
# Multi-replica deployments must run migrations as a separate operator step.
ENV MEMHOUSE_AUTO_MIGRATE=false
EXPOSE 4000
# Readiness is content-safe. Timings are seconds: 10 interval, 3 timeout, 30 startup,
# and 5 consecutive failures.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:4000/api/ready || exit 1

# Exec form gives the release PID 1 and direct shutdown signals.
CMD ["/app/bin/memhouse", "start"]
