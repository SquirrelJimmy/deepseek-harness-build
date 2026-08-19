# syntax=docker/dockerfile:1

ARG NODE_VERSION=24-bookworm-slim

FROM node:${NODE_VERSION}

ARG DSH_VERSION=0.1.0-rc.7

ENV DSH_HOME=/data/dsh \
    NODE_ENV=production \
    NODE_USE_ENV_PROXY=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      git \
      openssh-client \
      procps \
      ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@11.7.0 --activate \
    && npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
    && npm cache clean --force

RUN groupadd --gid 1000 dsh \
    && useradd --uid 1000 --gid dsh --create-home --shell /bin/bash dsh \
    && mkdir -p /data/dsh /workspace /opt/dsh \
    && chown -R dsh:dsh /data/dsh /workspace /opt/dsh

COPY --chown=dsh:dsh dsh.docker.cordis.yml /opt/dsh/docker.cordis.yml

USER dsh
WORKDIR /workspace

VOLUME ["/data/dsh", "/workspace"]
EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3080/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["dsh", "web", "--patch", "/opt/dsh/docker.cordis.yml"]
