#!/usr/bin/env bash
set -euo pipefail

: "${DSH_HOME:=/data/dsh}"
: "${DSH_RUNTIME_USER:=node}"
: "${DSH_FIX_OWNERSHIP:=true}"
: "${DSH_RUN_AS_ROOT:=false}"

fix_dir() {
  local dir="$1"

  mkdir -p "${dir}"

  if [[ "${DSH_FIX_OWNERSHIP}" == "true" ]]; then
    if ! chown -R "${DSH_RUNTIME_USER}:${DSH_RUNTIME_USER}" "${dir}"; then
      echo "Warning: could not chown ${dir}; mounted filesystem permissions may still block writes." >&2
    fi
  fi
}

if [[ "$(id -u)" == "0" ]]; then
  fix_dir "${DSH_HOME}"
  fix_dir /home/node/.cache
  fix_dir /home/node/.local
  fix_dir /workspace

  if [[ "${DSH_RUN_AS_ROOT}" == "true" ]]; then
    exec "$@"
  fi

  exec gosu "${DSH_RUNTIME_USER}" "$@"
fi

exec "$@"
