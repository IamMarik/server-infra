#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

OPERATION=""
OS_RELEASE_FILE="/etc/os-release"
LOCK_ROOT="/run/server-infra"
STATE_ROOT="/var/lib/server-infra"
CACHE_ROOT="/var/cache/server-infra"
DOCKER_KEYRING_ROOT="/etc/apt/keyrings"
DOCKER_KEY_FILE="$DOCKER_KEYRING_ROOT/docker.asc"
DOCKER_SOURCE_FILE="/etc/apt/sources.list.d/docker.sources"
TMPFILES_ROOT="/etc/tmpfiles.d"
TMPFILES_CONFIG="$TMPFILES_ROOT/server-infra.conf"
HOST_DISTRIBUTION=""
HOST_CODENAME=""
HOST_ARCHITECTURE=""
TEMP_KEY_FILE=""
TEMP_SOURCE_FILE=""
TEMP_TMPFILES_FILE=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/bootstrap.sh --check
  scripts/bootstrap.sh --apply

Operations:
  --check  Inspect clean-host prerequisites without changing the host.
  --apply  Idempotently prepare a Debian or Ubuntu host.

Apply provides:
  Git
  OpenSSH client
  CA certificates and curl
  restic
  Docker Engine, Buildx, and Docker Compose
  /run/server-infra
  /var/lib/server-infra
  /var/cache/server-infra

Docker is installed from Docker's official apt repository only when the
docker command is absent. An existing functional Docker and Compose
installation is accepted and is not replaced or upgraded.

Bootstrap never creates or changes /etc/server-infra, users, SSH, firewall,
application projects, Caddy configuration, DNS, or public traffic.

Apply requires Linux, root, systemd, apt-get, and an official Debian or Ubuntu
distribution.
USAGE
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --check)
        [[ -z "$OPERATION" ]] || \
          fail "Specify exactly one of --check or --apply"
        OPERATION="check"
        shift
        ;;
      --apply)
        [[ -z "$OPERATION" ]] || \
          fail "Specify exactly one of --check or --apply"
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

read_os_release_value() {
  local key="$1"
  local value

  if ! value="$(read_env_value "$OS_RELEASE_FILE" "$key")"; then
    fail "Missing $key in $OS_RELEASE_FILE"
  fi
  [[ -n "$value" ]] || fail "Empty $key in $OS_RELEASE_FILE"

  printf '%s' "$value"
}

detect_supported_host() {
  [[ "$(uname -s)" == "Linux" ]] || \
    fail "Bootstrap apply supports Linux only"
  [[ -f "$OS_RELEASE_FILE" ]] || \
    fail "Operating system release file is missing"
  validate_env_file "$OS_RELEASE_FILE"
  require_command apt-get
  require_command dpkg
  require_command dpkg-query
  require_command systemctl

  HOST_DISTRIBUTION="$(read_os_release_value "ID")"
  HOST_CODENAME="$(read_os_release_value "VERSION_CODENAME")"
  HOST_ARCHITECTURE="$(dpkg --print-architecture)"

  case "$HOST_DISTRIBUTION" in
    ubuntu | debian)
      ;;
    *)
      fail "Unsupported distribution: $HOST_DISTRIBUTION"
      ;;
  esac
  [[ "$HOST_CODENAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || \
    fail "Operating system codename has an invalid format"
  [[ "$HOST_ARCHITECTURE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || \
    fail "Package architecture has an invalid format"
}

package_is_installed() {
  local package_name="$1"
  local package_status

  package_status="$(
    dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null || true
  )"
  [[ "$package_status" == "ii "* ]]
}

show_path_status() {
  local path_value="$1"

  if [[ -d "$path_value" && ! -L "$path_value" ]]; then
    ok "directory: $path_value"
  elif [[ -e "$path_value" || -L "$path_value" ]]; then
    warn "unsafe or non-directory path: $path_value"
  else
    warn "directory is not prepared: $path_value"
  fi
}

show_tool_status() {
  if command -v git >/dev/null 2>&1; then
    ok "git: $(git --version)"
  else
    warn "git is not installed"
  fi

  if command -v ssh >/dev/null 2>&1; then
    ok "ssh client: $(command -v ssh)"
  else
    warn "OpenSSH client is not installed"
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

  if command -v restic >/dev/null 2>&1; then
    ok "restic: $(restic version)"
  else
    warn "restic is not installed"
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "docker: $(docker --version)"
    if docker compose version >/dev/null 2>&1; then
      ok "docker compose: $(docker compose version)"
    else
      warn "Docker Compose plugin is not available"
    fi
  else
    warn "docker is not installed"
  fi

  show_path_status "$LOCK_ROOT"
  show_path_status "$STATE_ROOT"
  show_path_status "$CACHE_ROOT"
}

run_check() {
  show_tool_status

  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "Apply is supported only on Debian or Ubuntu Linux hosts"
    ok "bootstrap check complete; no host changes made"
    return
  fi

  detect_supported_host
  ok "supported host: $HOST_DISTRIBUTION $HOST_CODENAME $HOST_ARCHITECTURE"
  ok "bootstrap check complete; no host changes made"
}

install_managed_directory() {
  local path_value="$1"

  [[ ! -L "$path_value" ]] || \
    fail "Managed bootstrap directory must not be a symlink: $path_value"
  install -d -o root -g root -m 0750 "$path_value"
}

install_repository_tools_if_missing() {
  local missing_packages=()

  command -v git >/dev/null 2>&1 || missing_packages+=("git")
  command -v ssh >/dev/null 2>&1 || missing_packages+=("openssh-client")
  command -v cmp >/dev/null 2>&1 || missing_packages+=("diffutils")
  if ((${#missing_packages[@]} == 0)); then
    ok "Repository and bootstrap tools are already installed; no package change needed"
    return
  fi

  log "Refreshing Debian package metadata for repository tools"
  env DEBIAN_FRONTEND=noninteractive apt-get update
  log "Installing repository tools: ${missing_packages[*]}"
  env DEBIAN_FRONTEND=noninteractive apt-get install \
    -y \
    --no-install-recommends \
    "${missing_packages[@]}"
  require_command git
  require_command ssh
  require_command cmp
}

docker_is_complete() {
  command -v docker >/dev/null 2>&1 && \
    docker compose version >/dev/null 2>&1
}

reject_conflicting_docker_packages() {
  local package_name
  local conflicting_packages=(
    docker.io
    docker-compose
    docker-compose-v2
    docker-doc
    podman-docker
    containerd
    runc
  )

  for package_name in "${conflicting_packages[@]}"; do
    if package_is_installed "$package_name"; then
      fail "Conflicting Docker package is installed: $package_name"
    fi
  done
}

install_or_validate_managed_file() {
  local temporary_file="$1"
  local destination_file="$2"
  local file_label="$3"

  if [[ -e "$destination_file" || -L "$destination_file" ]]; then
    [[ -f "$destination_file" && ! -L "$destination_file" ]] || \
      fail "$file_label is not a regular file: $destination_file"
    cmp -s "$temporary_file" "$destination_file" || \
      fail "Existing $file_label differs from the bootstrap contract"
    rm -f -- "$temporary_file"
    ok "$file_label already matches bootstrap contract"
    return
  fi

  install -o root -g root -m 0644 "$temporary_file" "$destination_file"
  rm -f -- "$temporary_file"
  ok "installed $file_label: $destination_file"
}

cleanup_bootstrap() {
  if [[ -n "$TEMP_KEY_FILE" && -f "$TEMP_KEY_FILE" ]]; then
    rm -f -- "$TEMP_KEY_FILE"
  fi
  TEMP_KEY_FILE=""

  if [[ -n "$TEMP_SOURCE_FILE" && -f "$TEMP_SOURCE_FILE" ]]; then
    rm -f -- "$TEMP_SOURCE_FILE"
  fi
  TEMP_SOURCE_FILE=""

  if [[ -n "$TEMP_TMPFILES_FILE" && -f "$TEMP_TMPFILES_FILE" ]]; then
    rm -f -- "$TEMP_TMPFILES_FILE"
  fi
  TEMP_TMPFILES_FILE=""

  release_deployment_lock
}

configure_docker_repository() {
  local docker_repository_url

  docker_repository_url="https://download.docker.com/linux/$HOST_DISTRIBUTION"
  [[ ! -L "$DOCKER_KEYRING_ROOT" ]] || \
    fail "Docker keyring directory must not be a symlink"
  install -d -o root -g root -m 0755 "$DOCKER_KEYRING_ROOT"
  [[ ! -L "${DOCKER_SOURCE_FILE%/*}" ]] || \
    fail "Docker apt source directory must not be a symlink"
  install -d -o root -g root -m 0755 "${DOCKER_SOURCE_FILE%/*}"

  TEMP_KEY_FILE="$(
    mktemp "$DOCKER_KEYRING_ROOT/.docker.asc.bootstrap.XXXXXX"
  )"
  chmod 0600 "$TEMP_KEY_FILE"
  log "Downloading Docker repository signing key"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    "$docker_repository_url/gpg" \
    --output "$TEMP_KEY_FILE"
  [[ -s "$TEMP_KEY_FILE" ]] || fail "Downloaded Docker signing key is empty"
  install_or_validate_managed_file \
    "$TEMP_KEY_FILE" \
    "$DOCKER_KEY_FILE" \
    "Docker signing key"
  TEMP_KEY_FILE=""

  TEMP_SOURCE_FILE="$(
    mktemp "${DOCKER_SOURCE_FILE%/*}/.docker.sources.bootstrap.XXXXXX"
  )"
  {
    printf '%s\n' "Types: deb"
    printf '%s\n' "URIs: $docker_repository_url"
    printf '%s\n' "Suites: $HOST_CODENAME"
    printf '%s\n' "Components: stable"
    printf '%s\n' "Architectures: $HOST_ARCHITECTURE"
    printf '%s\n' "Signed-By: $DOCKER_KEY_FILE"
  } > "$TEMP_SOURCE_FILE"
  chmod 0600 "$TEMP_SOURCE_FILE"
  install_or_validate_managed_file \
    "$TEMP_SOURCE_FILE" \
    "$DOCKER_SOURCE_FILE" \
    "Docker apt source"
  TEMP_SOURCE_FILE=""
}

install_docker_if_missing() {
  if docker_is_complete; then
    ok "Docker Engine and Compose are already available; no package changes made"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    fail "Existing Docker installation does not provide Docker Compose"
  fi

  reject_conflicting_docker_packages
  configure_docker_repository

  log "Refreshing package metadata with the Docker repository"
  env DEBIAN_FRONTEND=noninteractive apt-get update
  log "Installing Docker Engine and Compose"
  env DEBIAN_FRONTEND=noninteractive apt-get install \
    -y \
    --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  docker_is_complete || \
    fail "Docker Engine or Docker Compose is unavailable after installation"
}

configure_runtime_directory_persistence() {
  [[ ! -L "$TMPFILES_ROOT" ]] || \
    fail "systemd-tmpfiles configuration directory must not be a symlink"
  install -d -o root -g root -m 0755 "$TMPFILES_ROOT"
  TEMP_TMPFILES_FILE="$(
    mktemp "$TMPFILES_ROOT/.server-infra.conf.bootstrap.XXXXXX"
  )"
  printf '%s\n' \
    "d $LOCK_ROOT 0750 root root -" \
    > "$TEMP_TMPFILES_FILE"
  chmod 0600 "$TEMP_TMPFILES_FILE"
  install_or_validate_managed_file \
    "$TEMP_TMPFILES_FILE" \
    "$TMPFILES_CONFIG" \
    "server-infra tmpfiles configuration"
  TEMP_TMPFILES_FILE=""
  systemd-tmpfiles --create "$TMPFILES_CONFIG"
}

prepare_runtime_roots() {
  install_managed_directory "$LOCK_ROOT"
  install_managed_directory "$STATE_ROOT"
  install_managed_directory "$CACHE_ROOT"
}

ensure_docker_service_ready() {
  if systemctl cat docker.service >/dev/null 2>&1; then
    systemctl enable --now docker.service
    systemctl is-active --quiet docker.service || \
      fail "Docker service is not active"
  else
    warn "docker.service is not managed by systemd; validating the existing daemon"
  fi

  docker info >/dev/null || fail "Docker daemon is not available"
  docker compose version >/dev/null
}

run_apply() {
  [[ "$(uname -s)" == "Linux" ]] || fail "--apply requires Linux"
  [[ "$EUID" == "0" ]] || fail "--apply requires root privileges"
  detect_supported_host
  require_command env
  require_command install
  require_command mktemp
  require_command rm
  require_command systemd-tmpfiles

  "$SCRIPT_DIR/install-restic.sh" --apply
  require_command curl

  install_managed_directory "$LOCK_ROOT"
  acquire_deployment_lock "$LOCK_ROOT"
  trap cleanup_bootstrap EXIT

  install_repository_tools_if_missing
  require_command cmp
  install_docker_if_missing
  configure_runtime_directory_persistence
  prepare_runtime_roots

  ensure_docker_service_ready
  require_command git
  require_command ssh
  require_command restic

  show_tool_status
  ok "clean host bootstrap complete"
  warn "Active /etc/server-infra configuration and public traffic remain untouched"
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
      fail "Unsupported bootstrap operation: $OPERATION"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
