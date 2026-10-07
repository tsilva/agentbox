# syntax=docker/dockerfile:1
# Shared minimal runtime; each published target includes only its selected agent.
ARG BASE_IMAGE=debian:stable-slim@sha256:eb593cf2c358cacef45ca0a424bbc7d30cfa3466265fc2662b9466a0ca6ba1c5
ARG GO_IMAGE=golang:1.26-bookworm@sha256:dc9ad6c05acc7a88e5b71bde60a5fe3bd4b9f0db209011711b464107438a8107
FROM ${GO_IMAGE} AS broker-build
WORKDIR /src
COPY broker/ ./
RUN GOTOOLCHAIN=local go test ./... && CGO_ENABLED=0 GOTOOLCHAIN=local go build -trimpath -ldflags='-s -w' -o /agentbox-broker .

FROM ${BASE_IMAGE} AS core
LABEL org.opencontainers.image.title="agentbox" \
      org.opencontainers.image.description="Autonomous coding agents with explicit filesystem and network grants"
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq ripgrep tar && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash claude && mkdir -p \
    /opt/claude-code /opt/codex /opt/uv/bin /opt/agentbox \
    /home/claude/.config /home/claude/.local/bin \
    /home/claude/.claude/plugins /home/claude/.claude/plans /home/claude/.claude/runtime \
    /home/claude/.codex/log /home/claude/.codex/runtime /home/claude/.codex/sessions /home/claude/.codex/tmp \
    && chown -R claude:claude /opt/claude-code /opt/codex /opt/uv /home/claude \
    && chmod 755 /home/claude
COPY --from=broker-build /agentbox-broker /opt/agentbox/agentbox-broker
ENV PATH="/home/claude/.local/bin:/opt/uv/bin:/opt/claude-code:/opt/codex:$PATH" \
    NODE_OPTIONS="--dns-result-order=ipv4first" \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
# Python tools are optional. No pip dependencies enter the minimal images.
ARG PYTHON_TOOLS=0
ARG UV_VERSION=0.7.12
COPY requirements.txt constraints.txt /tmp/python-tools/
RUN set -eu; if [ "$PYTHON_TOOLS" = 1 ]; then \
      apt-get update && apt-get install -y --no-install-recommends python3 python3-venv python-is-python3 && \
      rm -rf /var/lib/apt/lists/*; \
      case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64) arch=aarch64 ;; *) exit 1 ;; esac; \
      artifact="uv-${arch}-unknown-linux-gnu.tar.gz"; \
      url="https://github.com/astral-sh/uv/releases/download/$UV_VERSION"; \
      cd /tmp && curl -fsSL -o "$artifact" "$url/$artifact" && \
      curl -fsSL -o "$artifact.sha256" "$url/$artifact.sha256" && sha256sum -c "$artifact.sha256" && \
      tar -xzf "$artifact" && install -m 755 "uv-${arch}-unknown-linux-gnu/uv" /opt/uv/bin/uv && \
      install -m 755 "uv-${arch}-unknown-linux-gnu/uvx" /opt/uv/bin/uvx && \
      cd /tmp/python-tools && uv pip install --system --break-system-packages \
        --exclude-newer "$(date --utc --date='7 days ago' +%Y-%m-%dT%H:%M:%SZ)" -r requirements.txt; \
    elif [ "$PYTHON_TOOLS" != 0 ]; then exit 1; fi && rm -rf /tmp/*
COPY --chmod=755 entrypoint.sh /home/claude/entrypoint.sh
COPY --chmod=755 scripts/install-agent-clis.sh /opt/agentbox/install-agent-clis.sh
USER claude
WORKDIR /workspace
ENTRYPOINT ["/home/claude/entrypoint.sh"]
ARG CACHE_BUST=stable
ARG CLAUDE_CODE_VERSION=latest
ARG CLAUDE_CODE_SHA256=
ARG CODEX_RELEASE_TAG=latest
ARG CODEX_SHA256=
ARG CODEX_CODE_MODE_SHA256=
ENV CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION CLAUDE_CODE_SHA256=$CLAUDE_CODE_SHA256 \
    CODEX_RELEASE_TAG=$CODEX_RELEASE_TAG CODEX_SHA256=$CODEX_SHA256 \
    CODEX_CODE_MODE_SHA256=$CODEX_CODE_MODE_SHA256

FROM core AS claude
RUN AGENT_RUNTIME=claude /opt/agentbox/install-agent-clis.sh
ENV AGENTBOX_RUNTIME=claude

FROM core AS codex
RUN AGENT_RUNTIME=codex /opt/agentbox/install-agent-clis.sh
ENV AGENTBOX_RUNTIME=codex

FROM ${BASE_IMAGE} AS broker
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* && useradd -m broker
COPY --from=broker-build /agentbox-broker /opt/agentbox/agentbox-broker
USER broker
ENTRYPOINT ["/opt/agentbox/agentbox-broker"]

# Compatibility target for development and the existing isolation suite.
FROM core AS development
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
USER claude
RUN AGENT_RUNTIME=both /opt/agentbox/install-agent-clis.sh
