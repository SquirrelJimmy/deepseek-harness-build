#!/usr/bin/env bash
set -euo pipefail

: "${DSH_HOME:=/data/dsh}"
: "${DSH_RUNTIME_USER:=node}"
: "${DSH_FIX_OWNERSHIP:=true}"
: "${DSH_RUN_AS_ROOT:=false}"
: "${DSH_NGINX_CONFIG_DIR:=${DSH_HOME}/nginx}"
: "${DSH_NGINX_CONFIG_FILE:=${DSH_NGINX_CONFIG_DIR}/nginx.conf}"
: "${DSH_NGINX_CONFIG_TEMPLATE:=/opt/dsh/nginx.conf.default}"
: "${DSH_NGINX_CONFIG_RESET:=false}"
: "${DSH_PUBLIC_URL:=}"

readonly DSH_NGINX_TEMPLATE_VERSION=2
# sha256 of the historical (v1) built-in nginx.conf. A persisted copy that still
# matches it was never customized, so it can be upgraded in place.
readonly DSH_NGINX_V1_SHA256="9cfcff2c335bfdf784cd6a974e575e43caef5f0c7b6650cce05d517d5260f081"

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

nginx_template_version() {
  local version

  version="$(sed -n 's/^# dsh-nginx-template v\([0-9][0-9]*\).*/\1/p' "$1")"
  printf '%s' "${version%%$'\n'*}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

upgrade_nginx_config() {
  local reason="$1"
  local backup="${DSH_NGINX_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"

  if [[ -f "${DSH_NGINX_CONFIG_FILE}" ]]; then
    cp -p "${DSH_NGINX_CONFIG_FILE}" "${backup}"
    log "backed up nginx config to ${backup}"
  fi

  log "installing nginx template v${DSH_NGINX_TEMPLATE_VERSION} (${reason})"
  cp "${DSH_NGINX_CONFIG_TEMPLATE}" "${DSH_NGINX_CONFIG_FILE}"
}

prepare_nginx_config() {
  local current_version=""

  mkdir -p "${DSH_NGINX_CONFIG_DIR}"

  if [[ -f "${DSH_NGINX_CONFIG_FILE}" ]]; then
    current_version="$(nginx_template_version "${DSH_NGINX_CONFIG_FILE}")"
  fi

  if [[ ! -f "${DSH_NGINX_CONFIG_FILE}" ]]; then
    log "initializing nginx config at ${DSH_NGINX_CONFIG_FILE} (template v${DSH_NGINX_TEMPLATE_VERSION})"
    cp "${DSH_NGINX_CONFIG_TEMPLATE}" "${DSH_NGINX_CONFIG_FILE}"
  elif [[ "${DSH_NGINX_CONFIG_RESET}" == "true" ]]; then
    upgrade_nginx_config "reset requested via DSH_NGINX_CONFIG_RESET"
  elif [[ "${current_version}" =~ ^[0-9]+$ ]] && (( current_version >= DSH_NGINX_TEMPLATE_VERSION )); then
    log "keeping nginx config ${DSH_NGINX_CONFIG_FILE} (template v${current_version})"
  elif [[ "${current_version}" =~ ^[0-9]+$ ]]; then
    upgrade_nginx_config "template v${current_version} -> v${DSH_NGINX_TEMPLATE_VERSION}"
  elif [[ "$(sha256_file "${DSH_NGINX_CONFIG_FILE}")" == "${DSH_NGINX_V1_SHA256}" ]]; then
    upgrade_nginx_config "unmodified legacy config detected"
  else
    log "warning: ${DSH_NGINX_CONFIG_FILE} looks customized; keeping it. Current template: ${DSH_NGINX_CONFIG_TEMPLATE}"
  fi

  chmod 0644 "${DSH_NGINX_CONFIG_FILE}" 2>/dev/null || true

  if [[ "$(id -u)" == "0" && "${DSH_RUN_AS_ROOT}" != "true" ]]; then
    chown "${DSH_RUNTIME_USER}:${DSH_RUNTIME_USER}" \
      "${DSH_NGINX_CONFIG_DIR}" \
      "${DSH_NGINX_CONFIG_FILE}"
  fi

  nginx -t -c "${DSH_NGINX_CONFIG_FILE}"
}

run_web_with_nginx() {
  local arg
  local dsh_pid
  local nginx_pid
  local status
  local has_public_url=0
  local -a dsh_args=("$@")

  if [[ -n "${DSH_PUBLIC_URL}" ]]; then
    for arg in "${dsh_args[@]}"; do
      case "${arg}" in
        --public-url | --public-url=*)
          has_public_url=1
          ;;
      esac
    done

    if (( has_public_url == 0 )); then
      dsh_args+=(--public-url "${DSH_PUBLIC_URL}")
      log "advertising public URL: ${DSH_PUBLIC_URL}"
    fi
  fi

  log "starting DeepSeek Harness web stack"
  log "dsh command: ${dsh_args[*]}"
  log "dsh home: ${DSH_HOME}"

  prepare_nginx_runtime
  prepare_nginx_config

  if [[ "$(id -u)" == "0" && "${DSH_RUN_AS_ROOT}" != "true" ]]; then
    log "starting dsh as ${DSH_RUNTIME_USER}"
    gosu "${DSH_RUNTIME_USER}" "${dsh_args[@]}" &
  else
    log "starting dsh as $(id -un)"
    "${dsh_args[@]}" &
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
