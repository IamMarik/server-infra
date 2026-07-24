#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

server_infra_output_is_pretty() {
  local output_fd="$1"

  case "${SERVER_INFRA_OUTPUT:-auto}" in
    pretty)
      return 0
      ;;
    plain)
      return 1
      ;;
    auto | "")
      [[ -t "$output_fd" && "${TERM:-}" != "dumb" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

server_infra_output_supports_unicode() {
  local locale_name="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"

  case "$locale_name" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

server_infra_output_uses_color() {
  local output_fd="$1"

  server_infra_output_is_pretty "$output_fd" || return 1
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

server_infra_emit() {
  local prefix="$1"
  local level="$2"
  local output_fd="$3"
  shift 3

  local suffix=""
  local symbol=""
  local color=""
  local reset=$'\033[0m'
  local message="$*"

  case "$level" in
    log)
      symbol="→"
      color=$'\033[36m'
      ;;
    ok)
      suffix="[ok]"
      symbol="✓"
      color=$'\033[32m'
      ;;
    warn)
      suffix="[warn]"
      symbol="⚠"
      color=$'\033[33m'
      ;;
    error)
      suffix="[error]"
      symbol="✗"
      color=$'\033[31m'
      ;;
  esac

  if ! server_infra_output_is_pretty "$output_fd"; then
    printf '%s%s %s\n' "$prefix" "$suffix" "$message" >&"$output_fd"
    return
  fi

  if ! server_infra_output_supports_unicode; then
    case "$level" in
      log) symbol="->" ;;
      ok) symbol="OK" ;;
      warn) symbol="WARN" ;;
      error) symbol="ERROR" ;;
    esac
  fi

  if server_infra_output_uses_color "$output_fd"; then
    printf '%s%s %s%s %s%s\n' \
      "$prefix" "$suffix" "$color" "$symbol" "$message" "$reset" \
      >&"$output_fd"
  else
    printf '%s%s %s %s\n' \
      "$prefix" "$suffix" "$symbol" "$message" \
      >&"$output_fd"
  fi
}

log() {
  server_infra_emit "[server-infra]" log 1 "$*"
}

ok() {
  server_infra_emit "[server-infra]" ok 1 "$*"
}

warn() {
  server_infra_emit "[server-infra]" warn 2 "$*"
}

fail() {
  server_infra_emit "[server-infra]" error 2 "$*"
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
}

release_deployment_lock() {
  if [[ -n "${DEPLOYMENT_LOCK_DIR:-}" && -d "$DEPLOYMENT_LOCK_DIR" ]]; then
    rmdir "$DEPLOYMENT_LOCK_DIR" 2>/dev/null || \
      warn "Unable to release deployment lock: $DEPLOYMENT_LOCK_DIR"
  fi

  DEPLOYMENT_LOCK_DIR=""
}

acquire_deployment_lock() {
  local lock_root="${1:-/run/server-infra}"

  [[ -d "$lock_root" ]] || fail "Runtime lock directory not found: $lock_root"
  [[ ! -L "$lock_root" ]] || fail "Runtime lock directory must not be a symlink: $lock_root"

  DEPLOYMENT_LOCK_DIR="$lock_root/operation.lock"

  if ! mkdir "$DEPLOYMENT_LOCK_DIR" 2>/dev/null; then
    fail "Another server-infra install or deployment is running"
  fi

  trap release_deployment_lock EXIT
}

parse_env_line() {
  local raw_line="$1"
  local source_name="$2"
  local line_number="$3"
  local value_length
  local first_character
  local last_character

  PARSED_ENV_KIND="skip"
  PARSED_ENV_KEY=""
  PARSED_ENV_VALUE=""

  raw_line="${raw_line%$'\r'}"

  if [[ "$raw_line" =~ ^[[:space:]]*$ ]] || \
    [[ "$raw_line" =~ ^[[:space:]]*# ]]; then
    return
  fi

  if [[ ! "$raw_line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
    fail "Invalid KEY=VALUE entry in $source_name at line $line_number"
  fi

  PARSED_ENV_KEY="${BASH_REMATCH[1]}"
  PARSED_ENV_VALUE="${BASH_REMATCH[2]}"
  value_length="${#PARSED_ENV_VALUE}"

  if ((value_length > 0)); then
    first_character="${PARSED_ENV_VALUE:0:1}"
    last_character="${PARSED_ENV_VALUE:value_length-1:1}"

    if [[ "$first_character" == '"' || "$last_character" == '"' ]]; then
      if ((value_length < 2)) || \
        [[ "$first_character" != '"' || "$last_character" != '"' ]]; then
        fail "Unbalanced double quote in $source_name at line $line_number"
      fi
      PARSED_ENV_VALUE="${PARSED_ENV_VALUE:1:value_length-2}"
    elif [[ "$first_character" == "'" || "$last_character" == "'" ]]; then
      if ((value_length < 2)) || \
        [[ "$first_character" != "'" || "$last_character" != "'" ]]; then
        fail "Unbalanced single quote in $source_name at line $line_number"
      fi
      PARSED_ENV_VALUE="${PARSED_ENV_VALUE:1:value_length-2}"
    fi
  fi

  PARSED_ENV_KIND="assignment"
}

validate_env_file() {
  local env_file="$1"
  local line=""
  local line_number=0
  local seen_keys=$'\n'

  [[ -f "$env_file" ]] || fail "Configuration file not found: $env_file"
  [[ -r "$env_file" ]] || fail "Configuration file is not readable: $env_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    parse_env_line "$line" "$env_file" "$line_number"

    [[ "$PARSED_ENV_KIND" == "assignment" ]] || continue

    if [[ "$seen_keys" == *$'\n'"$PARSED_ENV_KEY"$'\n'* ]]; then
      fail "Duplicate key $PARSED_ENV_KEY in $env_file"
    fi

    seen_keys+="$PARSED_ENV_KEY"$'\n'
  done < "$env_file"
}

read_env_value() {
  local env_file="$1"
  local requested_key="$2"
  local line=""
  local line_number=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    parse_env_line "$line" "$env_file" "$line_number"

    if [[ "$PARSED_ENV_KIND" == "assignment" && \
      "$PARSED_ENV_KEY" == "$requested_key" ]]; then
      printf '%s' "$PARSED_ENV_VALUE"
      return 0
    fi
  done < "$env_file"

  return 1
}

validate_relative_config_path() {
  local relative_path="$1"

  [[ -n "$relative_path" ]] || fail "Empty module configuration path"
  [[ "$relative_path" != /* ]] || fail "Module configuration path must be relative"
  [[ "$relative_path" != *".."* ]] || fail "Module configuration path must not contain .."
  [[ "$relative_path" =~ ^[a-z0-9]([a-z0-9./-]*[a-z0-9])?$ ]] || \
    fail "Invalid module configuration path: $relative_path"
  [[ "$relative_path" != *"//"* ]] || \
    fail "Invalid module configuration path: $relative_path"
  [[ "/$relative_path/" != *"/."* ]] || \
    fail "Hidden module configuration paths are not supported: $relative_path"
}

read_required_env_value() {
  local env_file="$1"
  local key="$2"
  local value

  if ! value="$(read_env_value "$env_file" "$key")"; then
    fail "Missing key $key in $env_file"
  fi

  printf '%s' "$value"
}

validate_systemd_unit_name() {
  local unit_name="$1"

  [[ "$unit_name" =~ ^[a-z0-9][a-z0-9_.-]*\.(service|timer|path|socket|target)$ ]] || \
    fail "Invalid systemd unit name: $unit_name"
}

validate_host_module_contract() {
  local module_name="$1"
  local module_dir="${2:-$REPO_ROOT/$module_name}"
  local manifest_file="$module_dir/module.env"
  local host_executables
  local host_public_executables
  local host_required_commands
  local host_preflight_executable
  local host_state_dirs
  local host_cache_dirs
  local systemd_units
  local systemd_enable_units
  local executable_paths=()
  local public_executable_paths=()
  local required_commands=()
  local managed_dirs=()
  local unit_paths=()
  local enable_units=()
  local relative_path
  local command_name
  local unit_name
  local managed_dir_list
  local declared_executables=$'\n'
  local declared_units=$'\n'
  local seen_destinations=$'\n'

  [[ -d "$module_dir" ]] || fail "Module directory not found: $module_name"
  [[ -f "$manifest_file" ]] || fail "Module manifest not found: $manifest_file"

  host_executables="$(read_required_env_value "$manifest_file" "HOST_EXECUTABLES")"
  host_public_executables="$(
    read_required_env_value "$manifest_file" "HOST_PUBLIC_EXECUTABLES"
  )"
  host_required_commands="$(
    read_required_env_value "$manifest_file" "HOST_REQUIRED_COMMANDS"
  )"
  host_preflight_executable="$(
    read_required_env_value "$manifest_file" "HOST_PREFLIGHT_EXECUTABLE"
  )"
  host_state_dirs="$(read_required_env_value "$manifest_file" "HOST_STATE_DIRS")"
  host_cache_dirs="$(read_required_env_value "$manifest_file" "HOST_CACHE_DIRS")"
  systemd_units="$(read_required_env_value "$manifest_file" "SYSTEMD_UNITS")"
  systemd_enable_units="$(
    read_required_env_value "$manifest_file" "SYSTEMD_ENABLE_UNITS"
  )"

  [[ -n "$systemd_units" ]] || \
    fail "SYSTEMD_UNITS must not be empty for host module: $module_name"

  if [[ -n "$host_executables" ]]; then
    read -r -a executable_paths <<< "$host_executables"

    for relative_path in "${executable_paths[@]}"; do
      validate_relative_config_path "$relative_path"
      [[ "$relative_path" == "bin/${relative_path##*/}" ]] || \
        fail "Host executable must be directly under bin/: $relative_path"
      [[ -f "$module_dir/$relative_path" ]] || \
        fail "Host executable not found: $module_dir/$relative_path"
      [[ ! -L "$module_dir/$relative_path" ]] || \
        fail "Host executable must not be a symlink: $module_dir/$relative_path"
      [[ -x "$module_dir/$relative_path" ]] || \
        fail "Host executable is not executable: $module_dir/$relative_path"

      if [[ "$seen_destinations" == *$'\n'"${relative_path##*/}"$'\n'* ]]; then
        fail "Duplicate host executable destination: ${relative_path##*/}"
      fi
      seen_destinations+="${relative_path##*/}"$'\n'
      declared_executables+="$relative_path"$'\n'
    done
  fi

  if [[ -n "$host_public_executables" ]]; then
    read -r -a public_executable_paths <<< "$host_public_executables"
    seen_destinations=$'\n'
    for relative_path in "${public_executable_paths[@]}"; do
      validate_relative_config_path "$relative_path"
      [[ "$declared_executables" == *$'\n'"$relative_path"$'\n'* ]] || \
        fail "Public executable must be declared in HOST_EXECUTABLES"
      if [[ "$seen_destinations" == \
        *$'\n'"${relative_path##*/}"$'\n'* ]]; then
        fail "Duplicate public executable destination: ${relative_path##*/}"
      fi
      seen_destinations+="${relative_path##*/}"$'\n'
    done
  fi

  if [[ -n "$host_required_commands" ]]; then
    read -r -a required_commands <<< "$host_required_commands"
    seen_destinations=$'\n'
    for command_name in "${required_commands[@]}"; do
      [[ "$command_name" =~ ^[a-z0-9][a-z0-9+._-]*$ ]] || \
        fail "Invalid required host command: $command_name"
      if [[ "$seen_destinations" == *$'\n'"$command_name"$'\n'* ]]; then
        fail "Duplicate required host command: $command_name"
      fi
      seen_destinations+="$command_name"$'\n'
    done
  fi

  if [[ -n "$host_preflight_executable" ]]; then
    validate_relative_config_path "$host_preflight_executable"
    [[ "$declared_executables" == \
      *$'\n'"$host_preflight_executable"$'\n'* ]] || \
      fail "HOST_PREFLIGHT_EXECUTABLE must be declared in HOST_EXECUTABLES"
  fi

  for managed_dir_list in "$host_state_dirs" "$host_cache_dirs"; do
    [[ -n "$managed_dir_list" ]] || continue
    read -r -a managed_dirs <<< "$managed_dir_list"
    seen_destinations=$'\n'
    for relative_path in "${managed_dirs[@]}"; do
      validate_relative_config_path "$relative_path"
      [[ "$relative_path" == "${relative_path##*/}" ]] || \
        fail "Host managed directory must not be nested: $relative_path"
      if [[ "$seen_destinations" == *$'\n'"$relative_path"$'\n'* ]]; then
        fail "Duplicate host managed directory: $relative_path"
      fi
      seen_destinations+="$relative_path"$'\n'
    done
    managed_dirs=()
  done

  read -r -a unit_paths <<< "$systemd_units"
  for relative_path in "${unit_paths[@]}"; do
    validate_relative_config_path "$relative_path"
    [[ "$relative_path" == "systemd/${relative_path##*/}" ]] || \
      fail "Systemd unit must be directly under systemd/: $relative_path"
    unit_name="${relative_path##*/}"
    validate_systemd_unit_name "$unit_name"
    [[ -f "$module_dir/$relative_path" ]] || \
      fail "Systemd unit not found: $module_dir/$relative_path"
    [[ ! -L "$module_dir/$relative_path" ]] || \
      fail "Systemd unit must not be a symlink: $module_dir/$relative_path"

    if [[ "$declared_units" == *$'\n'"$unit_name"$'\n'* ]]; then
      fail "Duplicate systemd unit destination: $unit_name"
    fi
    declared_units+="$unit_name"$'\n'
  done

  if [[ -n "$systemd_enable_units" ]]; then
    read -r -a enable_units <<< "$systemd_enable_units"

    seen_destinations=$'\n'
    for unit_name in "${enable_units[@]}"; do
      validate_systemd_unit_name "$unit_name"
      [[ "$declared_units" == *$'\n'"$unit_name"$'\n'* ]] || \
        fail "Enabled systemd unit is not declared in SYSTEMD_UNITS: $unit_name"

      if [[ "$seen_destinations" == *$'\n'"$unit_name"$'\n'* ]]; then
        fail "Duplicate enabled systemd unit: $unit_name"
      fi
      seen_destinations+="$unit_name"$'\n'
    done
  fi
}

validate_config_root_path() {
  local config_root="$1"
  local normalized_root="${config_root%/}"

  [[ "$config_root" == /* ]] || fail "--config-root must be an absolute path"
  [[ "$config_root" != *".."* ]] || fail "--config-root must not contain .."
  [[ "$config_root" != *"//"* ]] || fail "--config-root must not contain //"

  case "$normalized_root" in
    "" | / | /etc | /var | /run | /usr | /opt | /root | /home | /tmp)
      fail "Refusing unsafe configuration root: $config_root"
      ;;
  esac
}

managed_path_mode() {
  local managed_path="$1"

  case "$(uname -s)" in
    Linux)
      stat -c '%a' "$managed_path"
      ;;
    Darwin)
      stat -f '%Lp' "$managed_path"
      ;;
    *)
      fail "Unsupported platform for permission validation"
      ;;
  esac
}

validate_managed_path() {
  local managed_path="$1"
  local expected_type="$2"
  local expected_mode="${3#0}"
  local actual_mode
  local actual_owner

  [[ ! -L "$managed_path" ]] || \
    fail "Managed path must not be a symlink: $managed_path"

  case "$expected_type" in
    directory)
      [[ -d "$managed_path" ]] || fail "Managed directory not found: $managed_path"
      ;;
    file)
      [[ -f "$managed_path" ]] || fail "Managed file not found: $managed_path"
      ;;
    *)
      fail "Unknown managed path type: $expected_type"
      ;;
  esac

  actual_mode="$(managed_path_mode "$managed_path")"
  [[ "$actual_mode" == "$expected_mode" ]] || \
    fail "Expected mode 0$expected_mode for $managed_path; found 0$actual_mode"

  if [[ "$(uname -s)" == "Linux" ]]; then
    actual_owner="$(stat -c '%U:%G' "$managed_path")"
    [[ "$actual_owner" == "root:root" ]] || \
      fail "Expected owner root:root for $managed_path; found $actual_owner"
  fi
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
  ENVIRONMENT_DIR="$(require_environment "$1")"

  # shellcheck source=/dev/null
  source "$ENVIRONMENT_DIR/server.env"

  # shellcheck source=/dev/null
  source "$ENVIRONMENT_DIR/modules.env"

  [[ -n "${ENABLED_MODULES:-}" ]] || \
    fail "ENABLED_MODULES is empty in $ENVIRONMENT_DIR/modules.env"
}

require_module() {
  local module_name="$1"
  local module_dir="$REPO_ROOT/$module_name"

  [[ -d "$module_dir" ]] || fail "Module directory not found: $module_name"
  [[ -f "$module_dir/module.env" ]] || fail "Missing module manifest: $module_dir/module.env"

  printf '%s\n' "$module_dir"
}

load_module() {
  MODULE_DIR="$(require_module "$1")"

  MODULE_DESCRIPTION=""
  MODULE_VERSION=""
  REQUIRED_ENV=""

  # shellcheck source=/dev/null
  source "$MODULE_DIR/module.env"

  [[ -f "$MODULE_DIR/docker-compose.yml" ]] || \
    fail "Compose file not found: $MODULE_DIR/docker-compose.yml"
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
