#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/restore.sh [--config-root <absolute-path>] \
    --kind <config|data> \
    --target <absolute-empty-path> \
    [--snapshot <latest|id>] \
    [--include <absolute-path>]

The destination must not exist or must be an empty, non-symlink directory.
This command never restores over live configuration or data paths.
An include must be one configured path or a child of one.
USAGE
}

if (($# == 0)) || [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  [[ $# -gt 0 ]] && exit 0
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/../backup/bin/server-infra-backup" "$@" restore
