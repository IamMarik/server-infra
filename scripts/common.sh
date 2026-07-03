#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
  printf '[server-infra] %s\n' "$*"
}

ok() {
  printf '[server-infra][ok] %s\n' "$*"
}

warn() {
  printf '[server-infra][warn] %s\n' "$*" >&2
}

fail() {
  printf '[server-infra][error] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
}

require_environment() {
  local environment_name="$1"
  local environment_dir="$REPO_ROOT/environments/$environment_name"

  [[ -d "$environment_dir" ]] || fail "Environment not found: $environment_name"
  [[ -f "$environment_dir/server.env" ]] || fail "Missing environment file: $environment_dir/server.env"
  [[ -f "$environment_dir/modules.env" ]] || fail "Missing environment file: $environment_dir/modules.env"

  printf '%s\n' "$environment_dir"
}

load_environment() {
  local environment_name="$1"
  local environment_dir
  environment_dir="$(require_environment "$environment_name")"

  # shellcheck source=/dev/null
  source "$environment_dir/server.env"
  # shellcheck source=/dev/null
  source "$environment_dir/modules.env"

  [[ -n "${ENABLED_MODULES:-}" ]] || fail "ENABLED_MODULES is empty in $environment_dir/modules.env"

  printf '%s\n' "$environment_dir"
}

require_module() {
  local module_name="$1"
  local module_dir="$REPO_ROOT/$module_name"

  [[ -d "$module_dir" ]] || fail "Module directory not found: $module_name"
  [[ -f "$module_dir/module.env" ]] || fail "Missing module manifest: $module_dir/module.env"

  printf '%s\n' "$module_dir"
}

load_module() {
  local module_name="$1"
  local module_dir
  module_dir="$(require_module "$module_name")"

  MODULE_DESCRIPTION=""
  MODULE_VERSION=""
  REQUIRED_ENV=""

  # shellcheck source=/dev/null
  source "$module_dir/module.env"

  [[ -f "$module_dir/docker-compose.yml" ]] || fail "Compose file not found: $module_dir/docker-compose.yml"

  printf '%s\n' "$module_dir"
}


module_env_file() {
  local environment_dir="$1"
  local module_name="$2"
  printf '%s/%s/config.env\n' "$environment_dir" "$module_name"
}


ensure_docker_network() {
  local network_name="${1:-server-infra}"

  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    log "Creating Docker network: $network_name"
    docker network create "$network_name" >/dev/null
  fi
}
