#!/usr/bin/env bash
set -euo pipefail

: "${DSH_HOME:=/data/dsh}"
: "${DSH_RUNTIME_USER:=node}"
: "${DSH_FIX_OWNERSHIP:=true}"
: "${DSH_RUN_AS_ROOT:=false}"
: "${DSH_NGINX_CONFIG_DIR:=${DSH_HOME}/nginx}"
: "${DSH_NGINX_CONFIG_FILE:=${DSH_NGINX_CONFIG_DIR}/nginx.conf}"
: "${DSH_NGINX_CONFIG_TEMPLATE:=/opt/dsh/nginx.conf.default}"

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

prepare_nginx_runtime() {
  local runtime_dir="/tmp/dsh-nginx"

  mkdir -p "${runtime_dir}"
  chmod 0777 "${runtime_dir}" 2>/dev/null || true
  find "${runtime_dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

  mkdir -p \
    "${runtime_dir}/client_temp" \
    "${runtime_dir}/proxy_temp" \
    "${runtime_dir}/fastcgi_temp" \
    "${runtime_dir}/uwsgi_temp" \
    "${runtime_dir}/scgi_temp"

  chmod -R 0777 "${runtime_dir}" 2>/dev/null || true
}

prepare_nginx_config() {
  mkdir -p "${DSH_NGINX_CONFIG_DIR}"

  if [[ ! -f "${DSH_NGINX_CONFIG_FILE}" ]]; then
    log "initializing nginx config at ${DSH_NGINX_CONFIG_FILE}"
    cp "${DSH_NGINX_CONFIG_TEMPLATE}" "${DSH_NGINX_CONFIG_FILE}"
    chmod 0644 "${DSH_NGINX_CONFIG_FILE}" 2>/dev/null || true
  fi

  if [[ "$(id -u)" == "0" && "${DSH_RUN_AS_ROOT}" != "true" ]]; then
    chown "${DSH_RUNTIME_USER}:${DSH_RUNTIME_USER}" \
      "${DSH_NGINX_CONFIG_DIR}" \
      "${DSH_NGINX_CONFIG_FILE}"
  fi

  nginx -t -c "${DSH_NGINX_CONFIG_FILE}"
}

run_web_with_nginx() {
  local dsh_pid
  local nginx_pid
  local status

  log "starting DeepSeek Harness web stack"
  log "dsh command: $*"
  log "dsh home: ${DSH_HOME}"

  prepare_nginx_runtime
  prepare_nginx_config

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
  log "nginx config: ${DSH_NGINX_CONFIG_FILE}"
  nginx -c "${DSH_NGINX_CONFIG_FILE}" -g "daemon off;" &
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
