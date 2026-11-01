# DeepSeek Harness Build

This repository builds a Docker image for DeepSeek Harness from the latest upstream `dsh-v*` tag in `deepseek-ai/deepseek-harness`.

The GitHub workflow runs every day at `03:00 UTC` and can also be started manually. It checks whether `ghcr.io/<owner>/<repo>:<upstream-tag>` already exists before building. If the image tag exists, the scheduled build is skipped.

For manual runs, set `force_rebuild` to `true` to rebuild the latest upstream version and push over the existing image tags.

Alpha, beta, and dev upstream tags are published under their exact `dsh-v*` tag but never move `:latest`; `rc` builds do, because that is the upstream release channel.

Every newly published image is smoke-tested by the workflow (`scripts/smoke-test.sh`): it boots the image, performs a real launch-token login, and asserts that `/api` requests reach Harness instead of being rejected by the browser-trust fence.

## Image tags

- `ghcr.io/<owner>/<repo>:dsh-v0.2.1-rc.4`
- `ghcr.io/<owner>/<repo>:latest`

The Docker build receives the npm package version without the `dsh-v` prefix, for example:

```text
dsh-v0.2.1-rc.4 -> 0.2.1-rc.4
```

## Run

```sh
docker run --rm \
  -p 127.0.0.1:3080:3080 \
  -v dsh-home:/data/dsh \
  -v "$PWD/data/cache:/home/node/.cache" \
  -v "$PWD/data/local:/home/node/.local" \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/squirreljimmy/deepseek-harness-build:latest
```

DeepSeek Harness requires a launch token. On startup the container log prints a URL such as:

```text
dsh web: http://127.0.0.1:13080/?token=...
```

The host and port in that URL are the **internal** ones. Open the same path with the address you published, for example:

```text
http://localhost:3080/?token=...
```

The token exchange sets the session cookie and redirects to the GUI. If you publish the image elsewhere, set `DSH_PUBLIC_URL` so the container logs (and the agent's runtime GUI URL) show the address you actually use:

```sh
docker run --rm -p 127.0.0.1:8080:3080 \
  -e DSH_PUBLIC_URL=http://localhost:8080/ \
  ... ghcr.io/squirreljimmy/deepseek-harness-build:latest
```

View startup and runtime logs:

```sh
docker logs -f <container>
```

## Included tools

The image includes DeepSeek Harness plus a built-in nginx proxy and common utility tools for agent work:

- nginx
- Git, Git LFS, OpenSSH, curl, wget, jq, yq (upstream static binary), ripgrep, fd, fzf, file, tree, less
- Python 3, pip, venv, uv, uvx, `python`/`python3`
- Node.js, npm, pnpm (via corepack)
- build-essential, pkg-config, make, gcc
- sqlite3, rsync, tmux, nano, vim, xxd
- shellcheck, shfmt, bc, hexdump (`bsdextrautils`), zstd, 7z (`p7zip-full`)
- xmllint (`libxml2-utils`), envsubst (`gettext-base`), gpg (`gnupg`)
- zsh (default shell)
- lsof, strace, psmisc, procps, dnsutils, iputils-ping, netcat, socat
- poppler-utils (`pdftotext`, `pdfinfo`)
- zip, unzip, xz-utils, tzdata

The default locale is `C.UTF-8` and `SHELL` is `/bin/zsh`, so UTF-8 output (including Chinese text) works out of the box. `pip install` is not blocked by PEP 668, and `npm i -g` installs into `/home/node/.local` (already on `PATH` and persisted through the volume mount). Set `-e TZ=Asia/Shanghai` (or your zone) if you want local timestamps.

Heavyweight tools such as LibreOffice, pandoc, ffmpeg, ImageMagick, and `gh` are intentionally not installed; add them in a derived Dockerfile if your workload needs them. Office document conversion keeps using Harness's own LibreOffice Kit flow.

## Mounted directory permissions

The container starts as root only long enough to create and chown these writable directories, then runs DeepSeek Harness as the `node` user:

- `/data/dsh`
- `/home/node/.cache`
- `/home/node/.local`
- `/workspace`

If your host filesystem does not support `chown`, make sure those mounted directories are writable by UID `1000`, or run with `DSH_RUN_AS_ROOT=true` as a last resort.

The default command binds the Harness web server to `127.0.0.1:13080` inside the container. Built-in nginx listens on `0.0.0.0:3080` and forwards to Harness.

### Why nginx rewrites `Host` and `Origin`

Harness binds its session cookie to the request authority and its `/api` trust fence compares `Host` and `Origin` against the accepted authorities. A browser that reaches the container through `localhost:3080`, a LAN address, or a proxied domain is never one of them, so any mix of preserved and rewritten headers ends in `401` (cookie authority mismatch) or `403` (fence rejection).

The built-in configuration therefore rewrites `Host`, `Origin`, and `Sec-Fetch-Site` to the internal loopback authority for **every** route:

- the document route mints the cookie for `127.0.0.1:13080`,
- the API route presents `Host: 127.0.0.1:13080`,
- both then satisfy the same fence.

This is what makes the image work behind any domain or IP without `--trusted-host` declarations.

Trade-off: with the trust fence bypassed by the proxy, the effective protection is the launch token plus the `SameSite=Strict` authority-bound cookie. Keep port `3080` on `127.0.0.1` unless you front it with your own reverse proxy, and only publish it to networks you trust. An external reverse proxy should forward to `3080` unchanged (no need to touch `Host`).

## Persistent nginx configuration

The built-in nginx configuration is stored at `/data/dsh/nginx/nginx.conf`. Because `/data/dsh` is already the Harness persistent volume, no additional mount is required. On the first container start, the entrypoint copies the image template to that path.

The template carries a version marker (`# dsh-nginx-template v2`). On startup the entrypoint:

- keeps a persisted configuration whose marker is current or newer,
- upgrades an unmodified older default (matched by checksum) to the current template and writes a backup next to it,
- leaves a customized configuration untouched and logs a warning.

Backups are written as `nginx.conf.bak.<timestamp>`. To force a reset to the image template, start the container with `DSH_NGINX_CONFIG_RESET=true`.

To keep nginx configuration in a separate host directory instead, set the config directory and mount it:

```yaml
services:
  deepseek-harness:
    environment:
      DSH_NGINX_CONFIG_DIR: /data/nginx
    volumes:
      - ./data/dsh:/data/dsh
      - ./data/nginx:/data/nginx
```

After editing `nginx.conf`, restart the container. The entrypoint validates the persisted configuration with `nginx -t` before starting nginx, and prints the active config path in the container log.

Keep the host port mapping scoped to `127.0.0.1` unless you intentionally want LAN access. If you publish it through an external reverse proxy, add authentication or restrict the network path before exposing it.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `DSH_HOME` | `/data/dsh` | Harness persistent home |
| `DSH_PUBLIC_URL` | unset | URL advertised in the logs, `DSH_WEB_URL`, and the agent runtime GUI URL; appended as `--public-url` |
| `DSH_NGINX_CONFIG_DIR` | `$DSH_HOME/nginx` | Directory holding the persisted `nginx.conf` |
| `DSH_NGINX_CONFIG_RESET` | `false` | Overwrite the persisted config with the image template (backup first) |
| `DSH_FIX_OWNERSHIP` | `true` | Recursively chown the mounted writable directories to the runtime user |
| `DSH_RUN_AS_ROOT` | `false` | Skip the privilege drop and run Harness as root |
| `DSH_RUNTIME_USER` | `node` | User the web stack runs as |
| `TZ` | unset (UTC) | Container time zone, for example `Asia/Shanghai` |

## Tag overwrite behavior

GHCR image tags are mutable in this workflow. Pushing `latest` or `dsh-v...` again will move that tag to the new image digest. Existing consumers pinned by digest are not affected, but consumers using a tag must pull again to receive the new image.

## Local build

```sh
docker build \
  --build-arg DSH_VERSION=0.2.1-rc.4 \
  -t deepseek-harness:0.2.1-rc.4 \
  .
```

Verify the result (boots the image, exercises login and the `/api` path, checks the shell and tooling):

```sh
scripts/smoke-test.sh deepseek-harness:0.2.1-rc.4 3081
```
