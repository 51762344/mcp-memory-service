## Coolify-friendly image for MCP Memory Service.
##
## Upstream ships tools/docker/Dockerfile. This root-level copy exists because
## Coolify's "Dockerfile" buildpack looks for ./Dockerfile by default; without it
## every deployment would need the Dockerfile path set to tools/docker/Dockerfile
## plus a matching build context.
##
## Differences from tools/docker/Dockerfile:
##   - Data lives under /data (single volume) instead of /app/sqlite_db + /app/backups,
##     so one Coolify volume covers the database and its backups.
##   - HEALTHCHECK hits /api/health so the container reports its own state.
##
## Build:  docker build -t mcp-memory-service .
## Run:    docker run -p 8000:8000 -v mcp-data:/data mcp-memory-service
##
## On Coolify set the exposed port to 8000 and mount a volume at /data.

FROM python:3.12-slim

# MCP_MODE=http makes the entrypoint start the FastAPI/uvicorn server instead of
# the stdio MCP transport, which is what a hosted deployment needs.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MCP_MODE=http \
    MCP_MEMORY_STORAGE_BACKEND=sqlite_vec \
    MCP_MEMORY_SQLITE_PATH=/data/memory.db \
    MCP_MEMORY_BACKUPS_PATH=/data/backups \
    PYTHONPATH=/app/src \
    HF_HUB_DISABLE_TELEMETRY=1 \
    ANONYMIZED_TELEMETRY=false \
    CHROMA_TELEMETRY_IMPL=none

WORKDIR /app

# Minimal system packages with security updates.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    bash \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Install uv first so dependency resolution uses the lock file.
COPY pyproject.toml uv.lock README.md ./
COPY scripts/installation/install_uv.py ./
RUN python install_uv.py && mkdir -p /data/backups

COPY src/ /app/src/
COPY run_server.py ./
COPY tools/docker/docker-entrypoint-unified.sh /usr/local/bin/docker-entrypoint-unified.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-unified.sh

# The [sqlite] extra is onnxruntime + tokenizers, so embeddings go through ONNX
# and no torch wheel is pulled in. Swap it for [sqlite-ml] (sentence-transformers)
# when the full ML path is wanted; upstream's tools/docker/Dockerfile documents
# why torch is not installed by default.
#
# The import check fails the build instead of the deployment: a missing
# tokenizers package used to slip through and leave the service falling back to
# hash pseudo-vectors (upstream issue #162).
RUN python -m uv pip install -e . && \
    python -m uv pip install -e ".[sqlite]" && \
    python -c "import onnxruntime, tokenizers; print('onnxruntime', onnxruntime.__version__, '/ tokenizers', tokenizers.__version__, 'available')"

VOLUME ["/data"]

# 8000 for the HTTP API. MCP_HTTP_PORT overrides it at runtime.
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCP_HTTP_PORT:-8000}/api/health" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-unified.sh"]
