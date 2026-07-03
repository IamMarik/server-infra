#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/bootstrap.sh

Performs safe local checks for a new server.
This script intentionally does not mutate SSH or firewall settings yet.
USAGE
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  log "Checking base tools"
  require_command docker
  docker compose version >/dev/null || fail "Docker Compose is not available"
  log "Bootstrap checks passed"
}

main "$@"
