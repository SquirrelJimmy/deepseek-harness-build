# AGENTS.md

Guidance for agents working in this repository. Read this before changing anything.

## What this repo is

This is a **packaging repository**, not the DeepSeek Harness source. It builds a Docker image
around the upstream npm package `@deepseek-ai/dsh` and publishes it to GHCR
(`ghcr.io/<owner>/<repo>`). The image adds:

- a built-in nginx reverse proxy so the browser GUI works behind any host, port, or domain,
- a broad set of agent-friendly CLI tools (git, python/uv, node/pnpm, ripgrep, yq, ...),
- a root-to-`node` privilege-drop entrypoint with persisted config and volume handling.

The upstream project lives at `deepseek-ai/deepseek-harness` and is consumed as a versioned
`dsh-v*` tag. Do not vendor or patch Harness source here.

## Layout

| Path | Role |
| --- | --- |
| `Dockerfile` | Image definition: Node 24 base, apt tooling, yq static binary, pnpm, `dsh` install, volumes, healthcheck. |
| `docker-entrypoint.sh` | Runtime orchestration: fix mounted dir ownership, prepare nginx config, launch `dsh web` + nginx, signal handling. |
| `nginx.conf` | Built-in proxy template (v2). Listens on `0.0.0.0:3080`, forwards to `127.0.0.1:13080`. |
| `scripts/smoke-test.sh` | Boots the image and asserts login, proxy/fence behavior, shell, and tooling. |
| `.github/workflows/build.yml` | Daily upstream-tag resolution, build/push, and smoke-test job. |
| `README.md` | User-facing usage, env vars, and architecture rationale. |

## Architecture invariants

These are load-bearing; changing them breaks the image in non-obvious ways.

### nginx authority rewriting

Harness binds its session cookie to the request authority and its `/api` trust fence compares
`Host`/`Origin` against accepted authorities. `nginx.conf` therefore rewrites `Host`, `Origin`,
and `Sec-Fetch-Site` to the internal loopback authority (`127.0.0.1:13080`) on **every** route.
Mixing preserved and rewritten headers produces `401` (cookie mismatch) or `403` (fence
rejection). Keep the rewrite consistent across the document route and the API route.

### nginx template versioning

`nginx.conf` starts with `# dsh-nginx-template vN`, and `docker-entrypoint.sh` has a matching
`DSH_NGINX_TEMPLATE_VERSION`. Persisted configs in `$DSH_HOME/nginx/nginx.conf` are upgraded
only when their version marker is older (or they match the known unmodified v1 sha256). When
you change `nginx.conf`:

1. bump the marker in `nginx.conf`,
2. bump `DSH_NGINX_TEMPLATE_VERSION` in `docker-entrypoint.sh`,
3. keep `nginx -t` passing (the Dockerfile validates the template at build time).

Without both bumps, existing users keep the old config and never see your change.

### Entrypoint process model

- Starts as root only long enough to create/chown the mounted writable dirs, then drops to
  `DSH_RUNTIME_USER` (default `node`) via `gosu`.
- Only intercepts `dsh ... web` / `--profile web` commands; anything else is `exec`'d directly.
- Runs `dsh` and nginx as children, traps `INT`/`TERM`, and exits when either child dies
  (`wait -n`), because nginx alone would otherwise accept connections while dsh is gone.
- `DSH_PUBLIC_URL` is appended as `--public-url` only when the command does not already
  carry one.

### Build-time constraints

- `dsh >= 0.2` requires Node.js `>= 24.9`; the Dockerfile fails fast if the base image is older.
- `npm install -g @deepseek-ai/dsh` needs the explicit `--allow-scripts` list
  (`@deepseek-ai/dsh-subprocess-local`, `koffi`, `fs-ext`, `node-pty`, `@google/genai`,
  `protobufjs`). Adding a dependency that ships native bindings means extending that list.
- The Debian `yq` package is a jq wrapper and is not used; the upstream static binary is
  installed instead.
- Heavyweight tools (LibreOffice, pandoc, ffmpeg, ImageMagick, `gh`) are intentionally absent.
  Add them in a derived image, not here, unless the task explicitly asks.
- The image defaults to `/bin/zsh` (`SHELL=/bin/zsh` and the `node` user's login shell);
  repository scripts stay bash.

### Release channels

The workflow resolves the latest `dsh-v*` tag by semver. Pre-releases named `alpha`, `beta`,
or `dev` publish under their exact tag and **never** move `:latest`; `rc` builds do move
`:latest`. `:latest` and `dsh-v*` tags are mutable in GHCR; re-pushing moves the tag.

## Commands

```sh
# Syntax-check shell scripts (run before every change to them)
bash -n docker-entrypoint.sh scripts/smoke-test.sh

# Build the image locally
docker build --build-arg DSH_VERSION=0.2.1-rc.4 -t deepseek-harness:test .

# Validate the nginx template (absolute path required: a relative -c resolves
# against nginx's compile-time prefix). The Dockerfile build is the authoritative check.
nginx -t -c "$PWD/nginx.conf"

# Boot + verify (login, /api fence, shell, tooling, template version)
scripts/smoke-test.sh deepseek-harness:test 3081
```

CI runs `scripts/smoke-test.sh` against the published image after every real build. A change
is not verified until either the local smoke test or the workflow's smoke job passes.

## Conventions

- Bash: `set -euo pipefail`, `local` variables, `readonly` for constants, `log()` writing to
  stderr with an `[entrypoint]` prefix.
- Comments explain *why* (authority fence, ownership, yq packaging quirk), not *what*.
  Preserve them when editing; they encode hard-won context.
- Pin tool versions as `ARG`s (`DSH_VERSION`, `PNPM_VERSION`, `UV_VERSION`, `YQ_VERSION`).
- Keep the runtime user non-root; root is only for chown + privilege drop.
- Documentation and code comments are English. Keep it that way.
- Avoid drive-by reformatting. Changes are surgical and should be verifiable with the
  smoke test.

## Gotchas

- A mounted filesystem without `chown` support warns at startup; UID `1000` or
  `DSH_RUN_AS_ROOT=true` is the documented fallback.
- The container logs an internal URL (`127.0.0.1:13080`) with a launch token; the host must
  use the published port (e.g. `3080`) with the same token path.
- `:latest` is only meaningful for stable/rc upstream tags.
- Workflow triggers only on changes to `Dockerfile`, `docker-entrypoint.sh`, `nginx.conf`,
  `scripts/smoke-test.sh`, or the workflow file itself; a push touching only docs does not
  build.
