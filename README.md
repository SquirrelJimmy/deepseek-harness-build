# DeepSeek Harness Build

This repository builds a Docker image for DeepSeek Harness from the latest upstream `dsh-v*` tag in `deepseek-ai/deepseek-harness`.

The GitHub workflow runs every day at `03:00 UTC` and can also be started manually. It checks whether `ghcr.io/<owner>/<repo>:<upstream-tag>` already exists before building. If the image tag exists, the scheduled build is skipped.

For manual runs, set `force_rebuild` to `true` to rebuild the latest upstream version and push over the existing image tags.

## Image tags

- `ghcr.io/<owner>/<repo>:dsh-v0.1.0-rc.7`
- `ghcr.io/<owner>/<repo>:latest`

The Docker build receives the npm package version without the `dsh-v` prefix, for example:

```text
dsh-v0.1.0-rc.7 -> 0.1.0-rc.7
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

Open:

```text
http://localhost:3080
```

## Included tools

The image includes DeepSeek Harness plus common utility tools for agent work:

- Git, OpenSSH, curl, jq, ripgrep, file
- Python 3, pip, venv
- build-essential
- zip, unzip, xz-utils

## Mounted directory permissions

The container starts as root only long enough to create and chown these writable directories, then runs DeepSeek Harness as the `node` user:

- `/data/dsh`
- `/home/node/.cache`
- `/home/node/.local`
- `/workspace`

If your host filesystem does not support `chown`, make sure those mounted directories are writable by UID `1000`, or run with `DSH_RUN_AS_ROOT=true` as a last resort.

## Tag overwrite behavior

GHCR image tags are mutable in this workflow. Pushing `latest` or `dsh-v...` again will move that tag to the new image digest. Existing consumers pinned by digest are not affected, but consumers using a tag must pull again to receive the new image.

## Local build

```sh
docker build \
  --build-arg DSH_VERSION=0.1.0-rc.7 \
  -t deepseek-harness:0.1.0-rc.7 \
  .
```
