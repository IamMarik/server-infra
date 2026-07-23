#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

OPERATION=""
LOCK_ROOT="/run/server-infra"

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-restic.sh --check
  scripts/install-restic.sh --apply

Operations:
  --check  Inspect backup tool availability without changing the host.
  --apply  Install missing backup tools from Debian/Ubuntu repositories.

The apply operation installs these packages when missing:
  restic
  curl
  ca-certificates

Apply requires Linux, root, apt-get, and a Debian-compatible distribution.
Already available tools are not reinstalled or upgraded.
USAGE
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --check)
        [[ -z "$OPERATION" ]] || fail "Specify exactly one of --check or --apply"
        OPERATION="check"
        shift
        ;;
      --apply)
        [[ -z "$OPERATION" ]] || fail "Specify exactly one of --check or --apply"
        OPERATION="apply"
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$OPERATION" ]] || fail "Specify exactly one of --check or --apply"
}

is_debian_compatible() {
  [[ -f /etc/debian_version ]] && command -v apt-get >/dev/null 2>&1
}

show_tool_status() {
  if command -v restic >/dev/null 2>&1; then
    ok "restic: $(restic version)"
  else
    warn "restic is not installed"
  fi

  if command -v curl >/dev/null 2>&1; then
    ok "curl: $(command -v curl)"
  else
    warn "curl is not installed"
  fi

  if command -v update-ca-certificates >/dev/null 2>&1; then
    ok "CA certificates: available"
  else
    warn "CA certificate management is not available"
  fi
}

run_check() {
  show_tool_status

  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "Apply is supported only on Debian-compatible Linux hosts"
    ok "restic installation check complete; no host changes made"
    return
  fi

  is_debian_compatible || \
    fail "The host is not a supported Debian-compatible distribution"

  ok "Debian-compatible package manager"
  ok "restic installation check complete; no host changes made"
}

package_is_installed() {
  local package_name="$1"
  local package_status

  package_status="$(
    dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null || true
  )"
  [[ "$package_status" == "ii "* ]]
}

run_apply() {
  local missing_packages=()

  [[ "$(uname -s)" == "Linux" ]] || fail "--apply requires Linux"
  [[ "$EUID" == "0" ]] || fail "--apply requires root privileges"
  is_debian_compatible || \
    fail "The host is not a supported Debian-compatible distribution"

  require_command dpkg-query
  require_command env
  require_command install

  command -v restic >/dev/null 2>&1 || missing_packages+=("restic")
  command -v curl >/dev/null 2>&1 || missing_packages+=("curl")
  package_is_installed ca-certificates || missing_packages+=("ca-certificates")

  if ((${#missing_packages[@]} == 0)); then
    show_tool_status
    ok "backup tools are already installed; no package changes made"
    return
  fi

  [[ ! -L "$LOCK_ROOT" ]] || fail "Runtime lock root must not be a symlink"
  install -d -o root -g root -m 0750 "$LOCK_ROOT"
  acquire_deployment_lock "$LOCK_ROOT"

  log "Refreshing Debian package metadata"
  env DEBIAN_FRONTEND=noninteractive apt-get update

  log "Installing backup tools: ${missing_packages[*]}"
  env DEBIAN_FRONTEND=noninteractive apt-get install \
    -y \
    --no-install-recommends \
    "${missing_packages[@]}"

  require_command restic
  require_command curl
  command -v update-ca-certificates >/dev/null 2>&1 || \
    fail "CA certificate management is unavailable after package installation"

  show_tool_status
  ok "backup tools installed"
}

main() {
  parse_arguments "$@"

  case "$OPERATION" in
    check)
      run_check
      ;;
    apply)
      run_apply
      ;;
    *)
      fail "Unsupported operation: $OPERATION"
      ;;
  esac
}

main "$@"
