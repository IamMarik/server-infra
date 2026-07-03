#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/logs.sh <environment> <module>

Example:
  scripts/logs.sh prod-app monitoring
USAGE
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  local environment_name="${1:-}"
  local module_name="${2:-}"
  [[ -n "$environment_name" && -n "$module_name" ]] || { usage; exit 1; }

  require_environment "$environment_name" >/dev/null
  [[ -f "$REPO_ROOT/$module_name/docker-compose.yml" ]] || fail "Unknown module: $module_name"

  docker compose \
    -p "server_infra_${environment_name}_${module_name}" \
    -f "$REPO_ROOT/$module_name/docker-compose.yml" \
    logs -f --tail=100
}

main "$@"
