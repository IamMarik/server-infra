#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/check-repository.sh

Checks that required configuration examples exist and known runtime or secret
files are not tracked by Git. File contents are not printed.
USAGE
}

is_forbidden_tracked_path() {
  local file_path="$1"

  case "$file_path" in
    *.example | */*.example)
      return 1
      ;;
    server.env | */server.env | server.env.* | */server.env.* | \
    modules.env | */modules.env | modules.env.* | */modules.env.* | \
    config.env | */config.env | config.env.* | */config.env.* | \
    runtime.env | */runtime.env | runtime.env.* | */runtime.env.* | \
    backup/paths | backup/excludes | backup/freshness | \
    restic-password | */restic-password | \
    restic-password.* | */restic-password.* | \
    *.secret | */*.secret | \
    *.pem | */*.pem | \
    *.key | */*.key | \
    id_rsa | */id_rsa | \
    id_ed25519 | */id_ed25519 | \
    credentials | */credentials | \
    credentials.json | */credentials.json | \
    break-glass.txt | */break-glass.txt | \
    break-glass.txt.* | */break-glass.txt.* | \
    recovery/session.env | \
    proxy/Caddyfile.backup* | proxy/Caddyfile.before-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_required_examples() {
  local required_examples=(
    "server.env.example"
    "modules.env.example"
    "proxy/runtime.env.example"
    "proxy/conf.d/service.caddy.example"
    "backup/runtime.env.example"
    "backup/paths.example"
    "backup/excludes.example"
    "backup/freshness.example"
    "backup/break-glass.txt.example"
  )
  local example_path
  local missing=0

  for example_path in "${required_examples[@]}"; do
    if [[ ! -f "$REPO_ROOT/$example_path" ]]; then
      warn "Missing required configuration example: $example_path"
      missing=1
    fi
  done

  [[ "$missing" == "0" ]] || fail "Required configuration examples are missing"
}

check_tracked_paths() {
  local file_path
  local forbidden_paths=()

  while IFS= read -r -d '' file_path; do
    if is_forbidden_tracked_path "$file_path"; then
      forbidden_paths+=("$file_path")
    fi
  done < <(git -C "$REPO_ROOT" ls-files -z)

  if ((${#forbidden_paths[@]} > 0)); then
    for file_path in "${forbidden_paths[@]}"; do
      warn "Forbidden tracked runtime or secret file: $file_path"
    done
    fail "Repository contains forbidden tracked files"
  fi
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  (($# == 0)) || { usage; exit 1; }

  require_command git
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    fail "Repository check must run inside a Git worktree"

  check_required_examples
  check_tracked_paths

  ok "repository configuration guard passed"
}

main "$@"
