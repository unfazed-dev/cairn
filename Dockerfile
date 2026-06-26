# Cairn — multi-stage Dockerfile for the sync server + cloud control plane.
#
# Builds both binaries from the workspace in a single builder stage, then copies
# them into a slim runtime image. The `pg` feature is enabled on cairn-server so
# the real PgReplicator ships in the image.
#
#   docker build -t cairn .
#   docker run --rm cairn cairn-server   # default entrypoint arg
#   docker run --rm cairn cairn-cloud

# ---------- builder ----------
FROM rust:1.95-bookworm AS builder
WORKDIR /cairn
# Install needed system libs (none beyond what the base image provides for our
# deps; rusqlite uses `bundled` sqlite, reqwest uses rustls — no system deps).
COPY . .
# Build both binaries with the pg feature on cairn-server. Release profile.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/cairn/target \
    cargo build --release -p cairn-server --features pg -p cairn-cloud && \
    cp target/release/cairn-server /usr/local/bin/ && \
    cp target/release/cairn-cloud  /usr/local/bin/

# ---------- runtime ----------
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/cairn-server /usr/local/bin/cairn-server
COPY --from=builder /usr/local/bin/cairn-cloud  /usr/local/bin/cairn-cloud
# Default to the sync server; override CMD for the cloud binary.
ENV CAIRN_LOG=info,cairn=info RUST_LOG=info
EXPOSE 8800 9090
ENTRYPOINT ["cairn-server"]
