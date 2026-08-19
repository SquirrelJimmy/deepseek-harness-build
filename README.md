# DeepSeek Harness Build

This repository builds a Docker image for DeepSeek Harness from the latest upstream `dsh-v*` tag in `deepseek-ai/deepseek-harness`.

The GitHub workflow runs every day at `03:00 UTC` and can also be started manually. It checks whether `ghcr.io/<owner>/<repo>:<upstream-tag>` already exists before building. If the image tag exists, the build is skipped.

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
  -v "$PWD/workspace:/workspace" \
  ghcr.io/squirreljimmy/deepseek-harness-build:latest
```

Open:

```text
http://localhost:3080
```

## Local build

```sh
docker build \
  --build-arg DSH_VERSION=0.1.0-rc.7 \
  -t deepseek-harness:0.1.0-rc.7 \
  .
```
