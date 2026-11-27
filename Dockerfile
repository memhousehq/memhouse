# SPDX-License-Identifier: Apache-2.0
# The MemHouse container image (roadmap G21): the one binary on a distroless base.
#
#   docker build -t memhouse .                          # compile from this source tree
#   docker run --rm -p 7077:7077 -v memhouse:/data \
#     -e MEMHOUSE_DATABASE_URL=postgres://... -e MEMHOUSE_API_KEY=... memhouse
#
# What the image is:
# - non-root: user 65532 (distroless `nonroot`); nothing in it is setuid and it needs no capability;
# - no shell, no package manager, no curl: the health check is the binary's own `memhouse health`;
# - friendly to a read-only root filesystem: the only paths written are /data (MEMHOUSE_HOME:
#   the model cache, and for the Lite profile the configuration and the SQLite file) and /tmp;
# - no model inside: the local embedding model (bge-small-en-v1.5, MIT, about 130 MB) is fetched
#   into /data/models on the first start, at a revision and with checksums pinned in the binary,
#   so the image holds only this repository's code and its linked libraries. docs/install.md
#   says how to start without network access to the model hub.
#
# Base images are pinned by digest (the tag is for the reader); update the two together.
# Debian 13, not 12: the prebuilt ONNX Runtime that ort-sys links needs the C++ runtime of
# GCC 13 or newer (Debian 12 has GCC 12, and the link fails on `__cxa_call_terminate`).
ARG RUST_IMAGE=docker.io/library/rust:1.99.1-trixie@sha256:8a4e90c7946b74626488b1446f712c0fe0ed1a596cbd3d871684bc9c5433ae07
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:29ee70762214fe8190cea04ef1c0a84a8365879e047ce8f911ae5a5ab2355fa2
# Where the runtime stage takes the binary from: `build` compiles it here; `prebuilt` copies
# dist/linux-<arch>/memhouse from the build context, which is how the release pipeline puts the
# very binaries of the release archives into a multi-architecture image without compiling twice
# (and without emulation: the runtime stage runs no command).
ARG BINARY_STAGE=build

FROM ${RUST_IMAGE} AS build
WORKDIR /src
# Parallel rustc jobs; lower it on a small builder (the link step of the release profile is
# the memory peak).
ARG CARGO_BUILD_JOBS
ENV CARGO_TERM_COLOR=never CARGO_NET_RETRY=5
COPY . .
# `--locked`: exactly the dependency versions of Cargo.lock. The build script of ort-sys
# downloads ONNX Runtime (MIT) and verifies its checksum; nothing else is fetched but crates.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/target,sharing=locked \
    cargo build --release --locked -p memhouse-cli \
    && mkdir -p /out && cp target/release/memhouse /out/memhouse

FROM scratch AS prebuilt
ARG TARGETARCH
COPY dist/linux-${TARGETARCH}/memhouse /out/memhouse

# The stage named by BINARY_STAGE; the other one is never built.
FROM ${BINARY_STAGE} AS binary-source

# `docker build --target binary --output type=local,dest=out .` writes out/memhouse.
FROM scratch AS binary
COPY --from=binary-source /out/memhouse /memhouse

FROM ${RUNTIME_IMAGE} AS runtime
ARG VERSION=0.0.0-dev
ARG REVISION=unknown
ARG CREATED=1970-01-01T00:00:00Z
LABEL org.opencontainers.image.title="MemHouse" \
      org.opencontainers.image.description="Governed memory service for AI agents" \
      org.opencontainers.image.url="https://github.com/memhousehq/memhouse" \
      org.opencontainers.image.source="https://github.com/memhousehq/memhouse" \
      org.opencontainers.image.documentation="https://github.com/memhousehq/memhouse/blob/main/docs/install.md" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="MemHouse" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="gcr.io/distroless/cc-debian13:nonroot"
COPY --from=binary-source --chmod=0755 /out/memhouse /usr/local/bin/memhouse
COPY LICENSE NOTICE /usr/share/doc/memhouse/
# The server listens on every interface of the container; publish the port as narrowly as
# the deployment needs (`-p 127.0.0.1:7077:7077`).
ENV MEMHOUSE_HOME=/data MEMHOUSE_BIND=0.0.0.0:7077
USER 65532:65532
# Created here, as the unprivileged user, so that a fresh volume mounted at /data is its.
WORKDIR /data
VOLUME /data
EXPOSE 7077
# The server finishes its requests and stops its workers on SIGTERM.
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=4s --start-period=180s --retries=3 CMD ["/usr/local/bin/memhouse", "health"]
ENTRYPOINT ["/usr/local/bin/memhouse"]
CMD ["serve"]
