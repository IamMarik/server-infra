#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT_CREATED="$(mktemp -d "${TEST_TMPDIR%/}/bootstrap-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
BOOTSTRAP="$REPOSITORY_ROOT/scripts/bootstrap.sh"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[bootstrap-test][error] %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../../scripts/bootstrap.sh
source "$BOOTSTRAP"

plain_output="$(
  SERVER_INFRA_OUTPUT=plain ok "plain output"
)"
[[ "$plain_output" == "[server-infra][ok] plain output" ]] || \
  fail_test "Plain terminal output changed the stable log format"

automatic_output="$(
  SERVER_INFRA_OUTPUT=auto TERM=xterm-256color ok "redirected output"
)"
[[ "$automatic_output" == "[server-infra][ok] redirected output" ]] || \
  fail_test "Redirected automatic output was not plain"

unicode_output="$(
  SERVER_INFRA_OUTPUT=pretty \
    NO_COLOR=1 \
    LC_ALL= \
    LC_CTYPE= \
    LANG=server-infra.UTF-8 \
    ok "unicode output"
)"
[[ "$unicode_output" == "[server-infra][ok] ✓ unicode output" ]] || \
  fail_test "Pretty UTF-8 output did not use the success symbol"

ascii_output="$(
  SERVER_INFRA_OUTPUT=pretty \
    NO_COLOR=1 \
    LC_ALL=C \
    ok "ASCII output"
)"
[[ "$ascii_output" == "[server-infra][ok] OK ASCII output" ]] || \
  fail_test "Non-UTF-8 output did not use the ASCII fallback"

color_output="$(
  SERVER_INFRA_OUTPUT=pretty \
    NO_COLOR= \
    TERM=xterm-256color \
    LC_ALL= \
    LC_CTYPE= \
    LANG=server-infra.UTF-8 \
    ok "color output"
)"
[[ "$color_output" == \
  $'[server-infra][ok] \033[32m✓ color output\033[0m' ]] || \
  fail_test "Pretty terminal output did not use the success color"

OPERATION=""
parse_arguments --check
[[ "$OPERATION" == "check" ]] || fail_test "Check operation was not parsed"

if (OPERATION=""; parse_arguments --check --apply) >/dev/null 2>&1; then
  fail_test "Bootstrap accepted conflicting operations"
fi
if (OPERATION=""; parse_arguments --check --project-user deploy) \
  >/dev/null 2>&1; then
  fail_test "Bootstrap accepted the removed project-account option"
fi

OS_RELEASE_FILE="$TEST_ROOT/os-release"
printf '%s\n' \
  "ID=ubuntu" \
  "VERSION_CODENAME=noble" \
  > "$OS_RELEASE_FILE"

uname() {
  printf '%s\n' "Linux"
}

apt-get() {
  :
}

dpkg() {
  [[ "${1:-}" == "--print-architecture" ]]
  printf '%s\n' "amd64"
}

dpkg-query() {
  return 1
}

systemctl() {
  :
}

systemd-tmpfiles() {
  [[ "${1:-}" == "--create" ]]
  [[ "${2:-}" == "$TMPFILES_CONFIG" ]]
}

detect_supported_host
[[ "$HOST_DISTRIBUTION" == "ubuntu" ]] || \
  fail_test "Ubuntu distribution was not detected"
[[ "$HOST_CODENAME" == "noble" ]] || \
  fail_test "Ubuntu codename was not detected"
[[ "$HOST_ARCHITECTURE" == "amd64" ]] || \
  fail_test "Package architecture was not detected"

printf '%s\n' \
  "ID=alpine" \
  "VERSION_CODENAME=edge" \
  > "$OS_RELEASE_FILE"
if (detect_supported_host) >/dev/null 2>&1; then
  fail_test "Bootstrap accepted an unsupported distribution"
fi

printf '%s\n' \
  "ID=debian" \
  "VERSION_CODENAME=bookworm" \
  > "$OS_RELEASE_FILE"
detect_supported_host
[[ "$HOST_DISTRIBUTION" == "debian" ]] || \
  fail_test "Debian distribution was not detected"

install() {
  if [[ "${1:-}" == "-d" ]]; then
    mkdir -p "${*: -1}"
    return
  fi
  fail_test "Test attempted an unexpected file installation"
}

curl() {
  local output_file=""

  while (($# > 0)); do
    case "$1" in
      --output)
        output_file="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ -n "$output_file" ]] || fail_test "Fake curl did not receive --output"
  printf '%s\n' "test-docker-signing-key" > "$output_file"
}

DOCKER_KEYRING_ROOT="$TEST_ROOT/etc/apt/keyrings"
DOCKER_KEY_FILE="$DOCKER_KEYRING_ROOT/docker.asc"
DOCKER_SOURCE_FILE="$TEST_ROOT/etc/apt/sources.list.d/docker.sources"
HOST_DISTRIBUTION="debian"
HOST_CODENAME="bookworm"
HOST_ARCHITECTURE="amd64"
mkdir -p "$DOCKER_KEYRING_ROOT" "${DOCKER_SOURCE_FILE%/*}"
printf '%s\n' "test-docker-signing-key" > "$DOCKER_KEY_FILE"
printf '%s\n' \
  "Types: deb" \
  "URIs: https://download.docker.com/linux/debian" \
  "Suites: bookworm" \
  "Components: stable" \
  "Architectures: amd64" \
  "Signed-By: $DOCKER_KEY_FILE" \
  > "$DOCKER_SOURCE_FILE"

configure_docker_repository >/dev/null
if find "$TEST_ROOT/etc/apt" -type f -name '*.bootstrap.*' \
  -print -quit | grep -q .; then
  fail_test "Idempotent repository validation left temporary files"
fi

printf '%s\n' "unexpected source" > "$DOCKER_SOURCE_FILE"
if (configure_docker_repository) >/dev/null 2>&1; then
  fail_test "Bootstrap overwrote a conflicting Docker apt source"
fi

LOCK_ROOT="$TEST_ROOT/run/server-infra"
STATE_ROOT="$TEST_ROOT/var/lib/server-infra"
CACHE_ROOT="$TEST_ROOT/var/cache/server-infra"
TMPFILES_ROOT="$TEST_ROOT/etc/tmpfiles.d"
TMPFILES_CONFIG="$TMPFILES_ROOT/server-infra.conf"
mkdir -p "$TMPFILES_ROOT"
printf '%s\n' \
  "d $LOCK_ROOT 0750 root root -" \
  > "$TMPFILES_CONFIG"
configure_runtime_directory_persistence
prepare_runtime_roots
for managed_root in "$LOCK_ROOT" "$STATE_ROOT" "$CACHE_ROOT"; do
  [[ -d "$managed_root" ]] || \
    fail_test "Bootstrap runtime root was not prepared: $managed_root"
done
[[ ! -e "$TEST_ROOT/etc/server-infra" ]] || \
  fail_test "Bootstrap created active server configuration"

dpkg-query() {
  if [[ "${*: -1}" == "docker.io" ]]; then
    printf '%s\n' "ii "
    return
  fi
  return 1
}
if (reject_conflicting_docker_packages) >/dev/null 2>&1; then
  fail_test "Bootstrap accepted a conflicting Docker package"
fi

printf '[bootstrap-test][ok] clean-host bootstrap contract passed\n'
