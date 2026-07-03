#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/health.sh <environment>

Example:
  scripts/health.sh prod-app

Runs repository, environment, module, and Docker checks.
USAGE
}

check_module() {
  local module_name="$1"
  local module_dir

  module_dir="$(load_module "$module_name")"
  ok "module: $module_name"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  local environment_name="${1:-}"
  [[ -n "$environment_name" ]] || { usage; exit 1; }

  require_command docker

  local environment_dir
  environment_dir="$(load_environment "$environment_name")"

  ok "repository: $REPO_ROOT"
  ok "environment: $environment_name"
  ok "environment dir: $environment_dir"

  docker version >/dev/null || fail "Docker is not available"
  ok "docker"

  docker compose version >/dev/null || fail "Docker Compose is not available"
  ok "docker compose"

  for module_name in $ENABLED_MODULES; do
    check_module "$module_name"
  done

  ok "health check passed"
}

main "$@"
