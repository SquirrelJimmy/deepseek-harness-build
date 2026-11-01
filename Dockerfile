# syntax=docker/dockerfile:1

ARG NODE_VERSION=24-bookworm-slim
ARG UV_VERSION=0.13.6

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv
FROM node:${NODE_VERSION}

ARG DSH_VERSION=0.2.1-rc.4
ARG PNPM_VERSION=11.28.5
ARG YQ_VERSION=v4.54.1

ENV DSH_HOME=/data/dsh \
    NODE_ENV=production \
    NODE_USE_ENV_PROXY=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SHELL=/bin/zsh \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    NPM_CONFIG_FETCH_RETRIES=5 \
    NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=20000 \
    NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=120000 \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    UV_CACHE_DIR=/home/node/.cache/uv \
    UV_TOOL_DIR=/home/node/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=/home/node/.local/bin \
    XDG_CACHE_HOME=/home/node/.cache \
    XDG_DATA_HOME=/home/node/.local/share \
    PIP_CACHE_DIR=/home/node/.cache/pip \
    PATH=/home/node/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=uv /uv /uvx /usr/local/bin/

# dsh >= 0.2 requires Node.js 24.9+; fail the build instead of shipping a broken image.
RUN node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 24 || (major === 24 && minor < 9)) { console.error(`dsh requires Node.js >= 24.9.0, found ${process.versions.node}`); process.exit(1); }'

RUN DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      bash \
      bc \
      bsdextrautils \
      build-essential \
      ca-certificates \
      curl \
      dnsutils \
      fd-find \
      file \
      fzf \
      gettext-base \
      git \
      git-lfs \
      gnupg \
      gosu \
      iputils-ping \
      jq \
      less \
      libxml2-utils \
      lsof \
      nano \
      netcat-openbsd \
      nginx \
      openssh-client \
      p7zip-full \
      pkg-config \
      poppler-utils \
      procps \
      psmisc \
      python-is-python3 \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      rsync \
      shellcheck \
      shfmt \
      socat \
      sqlite3 \
      strace \
      tmux \
      tree \
      tzdata \
      unzip \
      vim \
      wget \
      xxd \
      xz-utils \
      zip \
      zsh \
      zstd \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && usermod -s /bin/zsh node

# The Debian `yq` package is a thin jq wrapper that lacks yq's own flags
# (`yq -o=json` fails); install the upstream static binary instead.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) yq_arch=amd64 ;; \
      arm64) yq_arch=arm64 ;; \
      *) echo "unsupported architecture for yq: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}"; \
    chmod +x /usr/local/bin/yq; \
    yq --version

RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate

RUN npm install -g \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,fs-ext,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
    && npm cache clean --force

# Let the runtime user install global npm packages into the persisted (and already
# PATH-visible) ~/.local prefix instead of the root-owned /usr/local tree.
ENV NPM_CONFIG_PREFIX=/home/node/.local

# Mounted workspaces commonly carry a host UID; without this git refuses them with
# "detected dubious ownership".
RUN git config --system --add safe.directory '*'

RUN mkdir -p \
      /data/dsh \
      /workspace \
      /opt/dsh \
      /home/node/.cache/uv \
      /home/node/.cache/pip \
      /home/node/.local/bin \
      /home/node/.local/share/uv/tools \
      /tmp/dsh-nginx/client_temp \
      /tmp/dsh-nginx/proxy_temp \
      /tmp/dsh-nginx/fastcgi_temp \
      /tmp/dsh-nginx/uwsgi_temp \
      /tmp/dsh-nginx/scgi_temp \
    && chown -R node:node /data/dsh /workspace /opt/dsh /home/node/.cache /home/node/.local \
    && chmod -R 0777 /tmp/dsh-nginx

COPY nginx.conf /opt/dsh/nginx.conf.default
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && nginx -t -c /opt/dsh/nginx.conf.default \
    && find /tmp/dsh-nginx -mindepth 1 -maxdepth 1 -exec rm -rf {} + \
    && chmod 0777 /tmp/dsh-nginx

WORKDIR /workspace

VOLUME ["/data/dsh", "/home/node/.cache", "/home/node/.local", "/workspace"]
EXPOSE 3080

# Both processes must be up: nginx alone keeps accepting connections while dsh is gone.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "const net=require('node:net');const probe=(port)=>new Promise((resolve)=>{const socket=net.connect(port,'127.0.0.1');socket.setTimeout(4000);socket.once('connect',()=>{socket.destroy();resolve(true)});socket.once('timeout',()=>{socket.destroy();resolve(false)});socket.once('error',()=>resolve(false))});Promise.all([probe(13080),probe(3080)]).then((results)=>process.exit(results.every(Boolean)?0:1))"

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["dsh", "--profile", "web", "--host", "127.0.0.1", "--port", "13080", "--no-open"]
