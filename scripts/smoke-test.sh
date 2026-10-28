#!/usr/bin/env bash
# Smoke test for the built DeepSeek Harness image.
#
# Usage: scripts/smoke-test.sh <image> [port]
#
# Boots the image, exercises the nginx -> dsh proxy path with a real launch-token
# login, and asserts that API calls reach dsh instead of being rejected by the
# authority-bound browser fence (401) or the /api trust fence (403).
set -euo pipefail

IMAGE="${1:-deepseek-harness-build:test}"
PORT="${2:-3081}"
NAME="dsh-smoke-$$"
COOKIE_JAR="$(mktemp)"

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  rm -f "${COOKIE_JAR}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "${NAME}" >&2 2>/dev/null || true
  exit 1
}

expect_status() {
  local want="$1"
  local got="$2"
  local label="$3"

  [[ "${got}" == "${want}" ]] || fail "${label}: expected HTTP ${want}, got ${got}"
  printf 'ok   %-28s HTTP %s\n' "${label}" "${got}"
}

expect_admitted() {
  local got="$1"
  local label="$2"

  case "${got}" in
    401 | 403) fail "${label}: HTTP ${got} means the request never reached dsh" ;;
  esac
  printf 'ok   %-28s HTTP %s (admitted)\n' "${label}" "${got}"
}

status_of() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@"
}

echo "== booting ${IMAGE} on 127.0.0.1:${PORT}"
docker run -d --name "${NAME}" -p "127.0.0.1:${PORT}:3080" "${IMAGE}" >/dev/null

TOKEN=""
for _ in $(seq 1 120); do
  if ! docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null | grep -q true; then
    fail "container exited during startup"
  fi

  TOKEN="$(docker logs "${NAME}" 2>&1 | grep -o 'token=[A-Za-z0-9_-]*' | head -n 1 || true)"
  [[ -n "${TOKEN}" ]] && break
  sleep 1
done

[[ -n "${TOKEN}" ]] || fail "no launch token in the container logs within 120s"
echo "ok   launch token found"

echo "== proxy + fence checks"
expect_status 401 "$(status_of "http://127.0.0.1:${PORT}/")" "GET / without cookie"
expect_status 303 "$(status_of -c "${COOKIE_JAR}" "http://127.0.0.1:${PORT}/?${TOKEN}")" "GET /?token exchange"
expect_status 200 "$(status_of -b "${COOKIE_JAR}" "http://127.0.0.1:${PORT}/")" "GET / with cookie"
expect_admitted "$(status_of -b "${COOKIE_JAR}" -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:${PORT}/api/turn")" "POST /api/turn"
expect_admitted "$(status_of -b "${COOKIE_JAR}" "http://127.0.0.1:${PORT}/api/unknown")" "GET /api/unknown"

echo "== shell + tooling checks"
docker exec "${NAME}" sh -c 'echo sh-ok' | grep -qx 'sh-ok' || fail "sh -c is broken"
echo "ok   /bin/sh"
docker exec "${NAME}" bash -c 'echo bash-ok' | grep -qx 'bash-ok' || fail "bash -c is broken"
echo "ok   /bin/bash"
docker exec "${NAME}" bash -lc 'test "${LANG}" = "C.UTF-8"' || fail "LANG is not C.UTF-8"
echo "ok   LANG=C.UTF-8"
docker exec "${NAME}" python3 -c 'print("中文")' | grep -qx '中文' || fail "python3 cannot print UTF-8"
echo "ok   python3 UTF-8"
docker exec "${NAME}" yq --version | grep -q 'yq' || fail "yq is not usable"
echo "ok   yq $(docker exec "${NAME}" yq --version 2>/dev/null | tr -d '\r')"
docker exec "${NAME}" dsh --version >/dev/null || fail "dsh --version failed"
echo "ok   dsh $(docker exec "${NAME}" dsh --version 2>/dev/null | head -n 1 | tr -d '\r')"
docker exec "${NAME}" git --version >/dev/null || fail "git is missing"
echo "ok   git"
docker exec "${NAME}" head -n 1 /data/dsh/nginx/nginx.conf | grep -q 'dsh-nginx-template v2' \
  || fail "persisted nginx config is not template v2"
echo "ok   nginx config template v2"

echo "== all checks passed"
