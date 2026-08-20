#!/usr/bin/env bash
set -euo pipefail

: "${DSH_HOME:=/data/dsh}"
: "${DSH_RUNTIME_USER:=node}"
: "${DSH_FIX_OWNERSHIP:=true}"
: "${DSH_RUN_AS_ROOT:=false}"

log() {
  printf '[entrypoint] %s\n' "$*" >&2
}

is_dsh_web_command() {
  if [[ "${1:-}" != "dsh" ]]; then
    return 1
  fi

  shift

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      web)
        return 0
        ;;
      --profile)
        if [[ "$#" -lt 2 ]]; then
          return 1
        fi
        [[ "${2:-}" == "web" ]] && return 0
        shift 2
        ;;
      --profile=web)
        return 0
        ;;
      --)
        return 1
        ;;
      -*)
        shift
        ;;
      *)
        return 1
        ;;
    esac
  done

  return 1
}

fix_dir() {
  local dir="$1"

  mkdir -p "${dir}"

  if [[ "${DSH_FIX_OWNERSHIP}" == "true" ]]; then
    if ! chown -R "${DSH_RUNTIME_USER}:${DSH_RUNTIME_USER}" "${dir}"; then
      echo "Warning: could not chown ${dir}; mounted filesystem permissions may still block writes." >&2
    fi
  fi
}

run_web_with_nginx() {
  local dsh_pid
  local nginx_pid
  local status

  log "starting DeepSeek Harness web stack"
  log "dsh command: $*"
  log "dsh home: ${DSH_HOME}"

  if [[ "$(id -u)" == "0" && "${DSH_RUN_AS_ROOT}" != "true" ]]; then
    log "starting dsh as ${DSH_RUNTIME_USER}"
    gosu "${DSH_RUNTIME_USER}" "$@" &
  else
    log "starting dsh as $(id -un)"
    "$@" &
  fi
  dsh_pid="$!"
  log "dsh pid: ${dsh_pid}"

  log "starting nginx on 0.0.0.0:3080"
  nginx -g "daemon off;" &
  nginx_pid="$!"
  log "nginx pid: ${nginx_pid}"

  terminate_children() {
    trap - INT TERM
    log "stopping dsh pid ${dsh_pid} and nginx pid ${nginx_pid}"
    kill -TERM "${dsh_pid}" "${nginx_pid}" 2>/dev/null || true
    wait "${dsh_pid}" "${nginx_pid}" 2>/dev/null || true
  }

  trap 'log "received SIGINT"; terminate_children; exit 130' INT
  trap 'log "received SIGTERM"; terminate_children; exit 143' TERM

  set +e
  wait -n "${dsh_pid}" "${nginx_pid}"
  status="$?"
  set -e

  log "one web stack process exited with status ${status}"
  terminate_children
  exit "${status}"
}

if [[ "$(id -u)" == "0" ]]; then
  fix_dir "${DSH_HOME}"
  fix_dir /home/node/.cache
  fix_dir /home/node/.local
  fix_dir /workspace

  if is_dsh_web_command "$@"; then
    run_web_with_nginx "$@"
  fi

  if [[ "${DSH_RUN_AS_ROOT}" == "true" ]]; then
    exec "$@"
  fi

  exec gosu "${DSH_RUNTIME_USER}" "$@"
fi

if is_dsh_web_command "$@"; then
  run_web_with_nginx "$@"
fi

exec "$@"
