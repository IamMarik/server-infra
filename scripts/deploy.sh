#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy.sh <environment>

Example:
  scripts/deploy.sh prod-app

Deploys all enabled infrastructure modules for the selected environment.
USAGE
}

verify_required_env() {
  local required_env="$1"
  local missing=0

  for variable_name in $required_env; do
    if [[ -z "${!variable_name:-}" ]]; then
      warn "Missing required env variable: $variable_name"
      missing=1
    fi
  done

  [[ "$missing" == "0" ]] || fail "Required environment variables are missing"
}

deploy_module() {
  local environment_name="$1"
  local environment_dir="$2"
  local module_name="$3"

  local module_dir
  local compose_file
  local module_env
  local project_name

  load_module "$module_name"

  local module_dir="$MODULE_DIR"
  local compose_file="$module_dir/docker-compose.yml"
  module_env="$(module_env_file "$environment_dir" "$module_name")"
  project_name="server_infra_${environment_name}_${module_name}"

  if [[ -n "${REQUIRED_ENV:-}" ]]; then
    [[ -f "$module_env" ]] || fail "Missing module config: $module_env"
    set -a
    # shellcheck source=/dev/null
    source "$module_env"
    set +a
    verify_required_env "$REQUIRED_ENV"
  fi

  log "Deploying module: $module_name"

  if [[ -f "$module_env" ]]; then
    MODULE_ENV_FILE="$module_env" docker compose \
      --env-file "$module_env" \
      -p "$project_name" \
      -f "$compose_file" \
      up -d
  else
    MODULE_ENV_FILE="$module_env" docker compose \
      -p "$project_name" \
      -f "$compose_file" \
      up -d
  fi
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  local environment_name="${1:-}"
  [[ -n "$environment_name" ]] || { usage; exit 1; }

  require_command docker

  load_environment "$environment_name"
  local environment_dir="$ENVIRONMENT_DIR"

  log "Deploying environment: $environment_name"
  ensure_docker_network "server-infra"

  for module_name in $ENABLED_MODULES; do
    deploy_module "$environment_name" "$environment_dir" "$module_name"
  done

  log "Deployment complete: $environment_name"
}

main "$@"
