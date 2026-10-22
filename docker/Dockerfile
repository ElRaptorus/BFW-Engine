# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Bifrost Forge World Engine release.
#
#   * Base: debian:12-slim (D16)
#   * Build stage: hexpm/elixir:1.20.x-erlang-29.x-debian-bookworm-slim
#   * Run stage: debian:12-slim + OTP release + openssl/ncurses runtime deps
#   * Healthcheck: curl -f http://localhost:4000/health
#   * Target size: <= 120 MB compressed
#
# Build cache strategy:
#   Layer 1 — system deps + Rust toolchain (changes: never)
#   Layer 2 — Hex/Rebar setup (changes: never)
#   Layer 3 — mix.exs + mix.lock only (changes: when deps change)
#   Layer 4 — deps.get + deps.compile with BuildKit caches (changes: when deps change)
#   Layer 5 — FEEL NIF crate pre-build into the Cargo target cache (changes: when native/ changes)
#   Layer 6 — app source + compile + release (changes: on every code change)
#
#   Every Cargo step shares the CARGO_TARGET_DIR cache mount, so Rustler's
#   compile inside `mix compile` reuses the dsntk build instead of starting over.

ARG ELIXIR_VERSION=1.20.3
ARG OTP_VERSION=29.0.5
ARG DEBIAN_VERSION=bookworm-20260824-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ==============================================================================
# Build stage
# ==============================================================================
FROM ${BUILDER_IMAGE} AS builder

# System build deps. git is required for Hex packages that fetch from GitHub.
# curl is needed for rustup (FEEL NIF via dsntk + Rustler).
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/*

# Rust toolchain (required by Rustler / dsntk FEEL NIF, Phase 0 Task 13).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /app

ENV MIX_ENV="prod" \
    LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    CARGO_TARGET_DIR="/cargo-target"

RUN mix local.hex --force && mix local.rebar --force

# --- Dependency layer (cached unless mix.exs/mix.lock change) ----------------
# Copy ONLY the dependency manifests — not the app source. This ensures
# deps.get + deps.compile layers survive source-only changes.
COPY mix.exs mix.lock ./

RUN --mount=type=cache,target=/root/.cache/hex \
    mix deps.get --only prod

# Compile-time config must be present before deps.compile: Ash, Spark and
# Phoenix read it via compile_env, and Mix recompiles them when it appears later.
COPY config/config.exs config/prod.exs config/

# Compile deps with BuildKit caches for Cargo registry + build artifacts.
# The Rust NIF is the most expensive part of the build;
# persistent Cargo caches avoid re-downloading crates on cache misses.
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/cargo-target \
    mix deps.compile

# --- FEEL NIF layer (rebuilt only when the crate changes) --------------------
COPY native/ native/

RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/cargo-target \
    cargo build --release --manifest-path native/feel_nif/Cargo.toml

# --- Application layer (rebuilt on every source change) ----------------------
COPY lib/ lib/
COPY priv/ priv/
COPY config/ config/
COPY rel/ rel/
COPY host/ host/

RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/cargo-target \
    mix compile && mix release

# ==============================================================================
# Run stage
# ==============================================================================
FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/^#.* en_US.UTF-8 /s/^#//' /etc/locale.gen \
 && locale-gen

ENV LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    LANGUAGE="en_US.UTF-8"

# Create a non-root runtime user.
RUN groupadd --system --gid 1000 bfw \
 && useradd --system --uid 1000 --gid bfw --home /app --shell /bin/false bfw \
 && mkdir -p /app \
 && chown bfw:bfw /app

WORKDIR /app

COPY --from=builder --chown=bfw:bfw /app/_build/prod/rel/bfw_engine ./
COPY --chown=bfw:bfw docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER bfw

EXPOSE 4000
EXPOSE 4001

# §14.1 — healthcheck against /health. Phase 0 step 7 mounts the route.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://localhost:4000/health || exit 1

# Docker stop sends SIGTERM; ensure the release shuts down cleanly.
STOPSIGNAL SIGTERM

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
