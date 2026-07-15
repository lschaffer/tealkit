# ── Stage 1: Build ──────────────────────────────────────────────────────────
# dart:stable tracks the latest Dart patch release and picks up all security
# fixes automatically. The build stage is fully discarded after AOT compilation
# — none of its packages ship in the final image, so any residual scanner
# warnings are irrelevant to the deployed container.
# To use the Docker Hardened Image instead (zero CVEs, requires `docker login
# dhi.io` first): replace the line below with "FROM dhi.io/dart:3 AS build"
FROM dart:3.12.0 AS build

WORKDIR /app

# Copy the server package and all local path dependencies.
COPY server/pubspec.yaml server/pubspec.lock ./
COPY server/ ./
COPY third_party/dart_duckdb/ /app/third_party/dart_duckdb/
COPY third_party/dartssh2/ /app/third_party/dartssh2/
COPY api/ /app/api/

# Write a minimal pubspec_overrides.yaml that redirects all path deps to
# their in-container locations. The root pubspec_overrides.yaml also has
# llamadart (Flutter-only) which doesn't exist here and would break pub get.
RUN printf 'dependency_overrides:\n  tealkit_api:\n    path: api\n  dart_duckdb:\n    path: third_party/dart_duckdb\n  dartssh2:\n    path: third_party/dartssh2\n' \
    > /app/pubspec_overrides.yaml

RUN dart pub get --no-precompile

# Build a CLI bundle so native assets (llamadart) are included.
RUN mkdir -p /app/build
RUN dart build cli --output /app/build

# ── Stage 2: Helper ──────────────────────────────────────────────────────────
# Statically-compiled BusyBox provides:
#   • mkdir to pre-create the data directory skeleton
#   • wget for Docker health checks (invoked as /usr/bin/wget at runtime)
FROM busybox:1.37 AS helper

RUN mkdir -p /data/db /data/output /data/logs /data/models

# ── Stage 3: Runtime ─────────────────────────────────────────────────────────
# Google Distroless cc — zero known CVEs, no shell, no package manager.
# Ships only glibc, libstdc++, libgcc-s and CA certificates — exactly what
# the AOT-compiled server binary and libduckdb.so require.
FROM gcr.io/distroless/cc-debian12 AS runtime

WORKDIR /app

# Server bundle (CLI executable + native assets)
COPY --from=build /app/build/bundle /app/bundle

# DuckDB shared library alongside the binary.
# LD_LIBRARY_PATH=/app lets the linker find it without ldconfig.
COPY third_party/dart_duckdb/linux/Libraries/release/libduckdb.so /app/libduckdb.so

# Statically-compiled BusyBox aliased as wget for Docker HEALTHCHECK.
# BusyBox:1.37's /bin/busybox is uclibc-static — works in any container.
# When argv[0] is "wget" BusyBox activates its wget applet automatically.
COPY --from=helper /bin/busybox /usr/bin/wget

# Pre-created data directory skeleton (server writes db, output and logs here)
COPY --from=helper /data /data

# Data volume — override mount point in docker-compose or with -v
VOLUME ["/data"]

ENV TEALKIT_DATA_DIR=/data \
    TEALKIT_PORT=7771 \
    TEALKIT_HOST=0.0.0.0 \
    LD_LIBRARY_PATH=/app:/app/bundle/lib

EXPOSE 7771

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/bin/wget", "-qO-", "http://localhost:7771/health"]

ENTRYPOINT ["/app/bundle/bin/tealkit_server"]
