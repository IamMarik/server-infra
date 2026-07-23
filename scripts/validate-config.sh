#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SUPPORTED_CONFIG_VERSION=1
CONFIG_ROOT="/etc/server-infra"

usage() {
  cat <<'USAGE'
Usage:
  scripts/validate-config.sh [--config-root <absolute-path>]

Validates external server-infra configuration without executing configuration
files or changing Docker, services, or the host.

Defaults to:
  --config-root /etc/server-infra
USAGE
}

is_placeholder_value() {
  local value="$1"

  case "$value" in
    example | replace-me | changeme | *.invalid | *'<'*'>'*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_declared_value() {
  local env_file="$1"
  local key="$2"
  local value

  if ! value="$(read_env_value "$env_file" "$key")"; then
    fail "Missing key $key in $env_file"
  fi

  printf '%s' "$value"
}

read_active_value() {
  local env_file="$1"
  local key="$2"
  local value

  value="$(read_declared_value "$env_file" "$key")"
  [[ -n "$value" ]] || fail "Empty required key $key in $env_file"

  if is_placeholder_value "$value"; then
    fail "Placeholder value for required key $key in $env_file"
  fi

  printf '%s' "$value"
}

validate_server_config() {
  local server_file="$CONFIG_ROOT/server.env"
  local config_version
  local instance
  local environment
  local timezone

  validate_env_file "$server_file"

  config_version="$(read_active_value "$server_file" "SERVER_INFRA_CONFIG_VERSION")"
  instance="$(read_active_value "$server_file" "SERVER_INFRA_INSTANCE")"
  environment="$(read_active_value "$server_file" "SERVER_INFRA_ENVIRONMENT")"
  timezone="$(read_active_value "$server_file" "SERVER_INFRA_TIMEZONE")"

  [[ "$config_version" == "$SUPPORTED_CONFIG_VERSION" ]] || \
    fail "Unsupported SERVER_INFRA_CONFIG_VERSION in $server_file"

  [[ "$instance" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || \
    fail "SERVER_INFRA_INSTANCE must use lowercase kebab-case"

  [[ "$environment" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || \
    fail "SERVER_INFRA_ENVIRONMENT must use lowercase kebab-case"

  [[ "$timezone" =~ ^[A-Za-z0-9_+./-]+$ && "$timezone" != *".."* ]] || \
    fail "SERVER_INFRA_TIMEZONE has an invalid format"

  ok "server configuration"
}

validate_module_runtime() {
  local module_name="$1"
  local module_dir="$REPO_ROOT/$module_name"
  local manifest_file="$module_dir/module.env"
  local runtime_file="$CONFIG_ROOT/$module_name/runtime.env"
  local description
  local module_version
  local required_env
  local required_keys=()
  local required_key
  local seen_required_keys=$'\n'

  [[ -d "$module_dir" ]] || fail "Module directory not found: $module_name"
  [[ -f "$manifest_file" ]] || fail "Module manifest not found: $manifest_file"
  [[ -f "$module_dir/docker-compose.yml" ]] || \
    fail "Compose file not found for module: $module_name"

  validate_env_file "$manifest_file"
  description="$(read_declared_value "$manifest_file" "MODULE_DESCRIPTION")"
  module_version="$(read_declared_value "$manifest_file" "MODULE_VERSION")"
  required_env="$(read_declared_value "$manifest_file" "REQUIRED_ENV")"

  [[ -n "$description" ]] || fail "MODULE_DESCRIPTION is empty for $module_name"
  [[ "$module_version" =~ ^[0-9]+$ ]] || \
    fail "MODULE_VERSION must be numeric for $module_name"

  if [[ -n "$required_env" ]]; then
    read -r -a required_keys <<< "$required_env"
  fi

  if ((${#required_keys[@]} > 0)); then
    validate_env_file "$runtime_file"
  elif [[ -f "$runtime_file" ]]; then
    validate_env_file "$runtime_file"
  fi

  for required_key in "${required_keys[@]}"; do
    [[ "$required_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || \
      fail "Invalid required key name in $manifest_file"

    if [[ "$seen_required_keys" == *$'\n'"$required_key"$'\n'* ]]; then
      fail "Duplicate required key in $manifest_file: $required_key"
    fi
    seen_required_keys+="$required_key"$'\n'

    read_active_value "$runtime_file" "$required_key" >/dev/null
  done

  ok "module configuration: $module_name"
}

validate_modules_config() {
  local modules_file="$CONFIG_ROOT/modules.env"
  local enabled_modules
  local module_names=()
  local module_name
  local seen_modules=$'\n'

  validate_env_file "$modules_file"
  enabled_modules="$(read_active_value "$modules_file" "ENABLED_MODULES")"
  read -r -a module_names <<< "$enabled_modules"

  ((${#module_names[@]} > 0)) || fail "ENABLED_MODULES must not be empty"

  for module_name in "${module_names[@]}"; do
    [[ "$module_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || \
      fail "Invalid module name in $modules_file: $module_name"

    if [[ "$seen_modules" == *$'\n'"$module_name"$'\n'* ]]; then
      fail "Duplicate module in $modules_file: $module_name"
    fi
    seen_modules+="$module_name"$'\n'

    validate_module_runtime "$module_name"
  done
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --config-root)
        (($# >= 2)) || fail "Missing value for --config-root"
        CONFIG_ROOT="$2"
        shift 2
        ;;
      --config-root=*)
        CONFIG_ROOT="${1#*=}"
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
}

main() {
  parse_arguments "$@"

  [[ "$CONFIG_ROOT" == /* ]] || fail "--config-root must be an absolute path"
  [[ -d "$CONFIG_ROOT" ]] || fail "Configuration root not found: $CONFIG_ROOT"

  validate_server_config
  validate_modules_config

  ok "external configuration: $CONFIG_ROOT"
}

main "$@"
