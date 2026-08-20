# syntax=docker/dockerfile:1

ARG NODE_VERSION=24-bookworm-slim
ARG UV_VERSION=0.12.5

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv
FROM node:${NODE_VERSION}

ARG DSH_VERSION=0.1.0-rc.7

ENV DSH_HOME=/data/dsh \
    NODE_ENV=production \
    NODE_USE_ENV_PROXY=1 \
    UV_CACHE_DIR=/home/node/.cache/uv \
    UV_TOOL_DIR=/home/node/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=/home/node/.local/bin \
    XDG_CACHE_HOME=/home/node/.cache \
    XDG_DATA_HOME=/home/node/.local/share \
    PIP_CACHE_DIR=/home/node/.cache/pip \
    PATH=/home/node/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=uv /uv /uvx /usr/local/bin/

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      fd-find \
      file \
      fzf \
      git \
      git-lfs \
      gosu \
      jq \
      less \
      nginx \
      openssh-client \
      procps \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      rsync \
      sqlite3 \
      tree \
      unzip \
      vim-tiny \
      xz-utils \
      yq \
      zip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && corepack enable \
    && corepack prepare pnpm@11.7.0 --activate \
    && npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
    && npm cache clean --force

RUN mkdir -p \
      /data/dsh \
      /workspace \
      /opt/dsh \
      /home/node/.cache/uv \
      /home/node/.cache/pip \
      /home/node/.local/bin \
      /home/node/.local/share/uv/tools \
    && chown -R node:node /data/dsh /workspace /opt/dsh /home/node/.cache /home/node/.local

COPY nginx.conf /etc/nginx/nginx.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && nginx -t

WORKDIR /workspace

VOLUME ["/data/dsh", "/home/node/.cache", "/home/node/.local", "/workspace"]
EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3080/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["dsh", "--profile", "web", "--host", "127.0.0.1", "--port", "13080", "--no-open"]
