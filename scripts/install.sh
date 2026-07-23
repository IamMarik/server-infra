#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

CONFIG_ROOT="/etc/server-infra"
RUN_ROOT="/run/server-infra"
OPERATION=""
INSTALL_EXAMPLES=0
REQUESTED_MODULES=()
SELECTED_MODULES=()
SELECTED_HAS_HOST=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/install.sh --module <name> [--module <name> ...] --check
  scripts/install.sh --module <name> [--module <name> ...] --apply
                     [--install-examples]
                     [--config-root <absolute-path>]

If --module is omitted and <config-root>/modules.env exists, enabled modules
are read from that file without executing it.

Operations:
  --check  Validate prerequisites and show the intended layout without changes.
  --apply  Prepare the host layout. Requires Linux and root.

Options:
  --install-examples  Atomically install repository examples as *.example.
                      Active runtime files and secrets are never created.

Examples:
  scripts/install.sh --module proxy --check
  scripts/install.sh --module proxy --apply --install-examples
USAGE
}

read_manifest_value() {
  local manifest_file="$1"
  local key="$2"
  local value

  if ! value="$(read_env_value "$manifest_file" "$key")"; then
    fail "Missing key $key in $manifest_file"
  fi

  printf '%s' "$value"
}

select_modules() {
  local modules_file="$CONFIG_ROOT/modules.env"
  local enabled_modules

  if ((${#REQUESTED_MODULES[@]} > 0)); then
    SELECTED_MODULES=("${REQUESTED_MODULES[@]}")
    return
  fi

  [[ -f "$modules_file" ]] || \
    fail "Specify --module because $modules_file does not exist"

  validate_env_file "$modules_file"
  if ! enabled_modules="$(read_env_value "$modules_file" "ENABLED_MODULES")"; then
    fail "Missing ENABLED_MODULES in $modules_file"
  fi
  [[ -n "$enabled_modules" ]] || fail "ENABLED_MODULES is empty in $modules_file"

  read -r -a SELECTED_MODULES <<< "$enabled_modules"
}

check_module_contract() {
  local module_name="$1"
  local module_dir="$REPO_ROOT/$module_name"
  local manifest_file="$module_dir/module.env"
  local module_driver
  local runtime_mode
  local config_dirs
  local config_files
  local example_files
  local path_entries=()
  local relative_path

  [[ "$module_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || \
    fail "Invalid module name: $module_name"
  [[ -d "$module_dir" ]] || fail "Module directory not found: $module_name"
  [[ -f "$manifest_file" ]] || fail "Module manifest not found: $manifest_file"

  validate_env_file "$manifest_file"
  module_driver="$(read_manifest_value "$manifest_file" "MODULE_DRIVER")"
  runtime_mode="$(read_manifest_value "$manifest_file" "RUNTIME_ENV_MODE")"
  config_dirs="$(read_manifest_value "$manifest_file" "REQUIRED_CONFIG_DIRS")"
  config_files="$(read_manifest_value "$manifest_file" "REQUIRED_CONFIG_FILES")"
  example_files="$(read_manifest_value "$manifest_file" "EXAMPLE_CONFIG_FILES")"

  case "$module_driver" in
    compose)
      [[ -f "$module_dir/docker-compose.yml" ]] || \
        fail "Compose file not found for module: $module_name"
      require_command docker
      docker compose version >/dev/null || fail "Docker Compose is not available"
      ;;
    host)
      SELECTED_HAS_HOST=1
      validate_host_module_contract "$module_name"
      if [[ "$OPERATION" == "apply" ]]; then
        [[ "$(uname -s)" == "Linux" ]] || \
          fail "Applying host modules requires Linux: $module_name"
      fi
      ;;
    *)
      fail "Unsupported MODULE_DRIVER in $manifest_file: $module_driver"
      ;;
  esac

  [[ "$runtime_mode" == "0600" || "$runtime_mode" == "0640" ]] || \
    fail "RUNTIME_ENV_MODE must be 0600 or 0640 in $manifest_file"

  if [[ -n "$config_dirs" ]]; then
    read -r -a path_entries <<< "$config_dirs"
    for relative_path in "${path_entries[@]}"; do
      validate_relative_config_path "$relative_path"
    done
  fi

  path_entries=()
  if [[ -n "$config_files" ]]; then
    read -r -a path_entries <<< "$config_files"
    for relative_path in "${path_entries[@]}"; do
      validate_relative_config_path "$relative_path"
    done
  fi

  path_entries=()
  if [[ -n "$example_files" ]]; then
    read -r -a path_entries <<< "$example_files"
    for relative_path in "${path_entries[@]}"; do
      validate_relative_config_path "$relative_path"
      [[ "$relative_path" == *.example ]] || \
        fail "Tracked config template must end in .example: $relative_path"
      [[ -f "$module_dir/$relative_path" ]] || \
        fail "Module example not found: $module_dir/$relative_path"
    done
  fi

  ok "module install contract: $module_name"
}

validate_selected_modules() {
  local module_name
  local seen_modules=$'\n'

  ((${#SELECTED_MODULES[@]} > 0)) || fail "At least one module is required"

  for module_name in "${SELECTED_MODULES[@]}"; do
    if [[ "$seen_modules" == *$'\n'"$module_name"$'\n'* ]]; then
      fail "Duplicate module: $module_name"
    fi
    seen_modules+="$module_name"$'\n'

    check_module_contract "$module_name"
  done
}

show_install_plan() {
  local module_name
  local manifest_file
  local config_dirs
  local config_files
  local path_entries=()
  local relative_path

  log "Configuration root: $CONFIG_ROOT"
  log "Runtime lock root: $RUN_ROOT"

  for module_name in "${SELECTED_MODULES[@]}"; do
    log "Module directory: $CONFIG_ROOT/$module_name"
    manifest_file="$REPO_ROOT/$module_name/module.env"
    config_dirs="$(read_manifest_value "$manifest_file" "REQUIRED_CONFIG_DIRS")"
    config_files="$(read_manifest_value "$manifest_file" "REQUIRED_CONFIG_FILES")"

    path_entries=()
    if [[ -n "$config_dirs" ]]; then
      read -r -a path_entries <<< "$config_dirs"
      for relative_path in "${path_entries[@]}"; do
        log "Module config directory: $CONFIG_ROOT/$module_name/$relative_path"
      done
    fi

    path_entries=()
    if [[ -n "$config_files" ]]; then
      read -r -a path_entries <<< "$config_files"
      for relative_path in "${path_entries[@]}"; do
        log "Required module config: $CONFIG_ROOT/$module_name/$relative_path"
      done
    fi
  done

  if [[ "$INSTALL_EXAMPLES" == "1" ]]; then
    log "Repository examples will be installed only as *.example"
  fi
}

install_directory() {
  local directory_path="$1"

  [[ ! -L "$directory_path" ]] || \
    fail "Refusing to use a symlink as a managed directory: $directory_path"
  install -d -o root -g root -m 0750 "$directory_path"
}

install_example_atomic() {
  local source_file="$1"
  local destination_file="$2"
  local destination_dir="${destination_file%/*}"
  local destination_name="${destination_file##*/}"
  local temporary_file

  [[ "$destination_file" == *.example ]] || \
    fail "Refusing to install active configuration: $destination_file"
  [[ -f "$source_file" ]] || fail "Example source not found: $source_file"
  [[ -d "$destination_dir" ]] || \
    fail "Example destination directory not found: $destination_dir"

  temporary_file="$(mktemp "$destination_dir/.${destination_name}.tmp.XXXXXX")"
  if ! install -o root -g root -m 0640 "$source_file" "$temporary_file"; then
    rm -f -- "$temporary_file"
    fail "Unable to prepare example: $destination_file"
  fi

  if ! mv -f -- "$temporary_file" "$destination_file"; then
    rm -f -- "$temporary_file"
    fail "Unable to install example: $destination_file"
  fi

  ok "installed example: $destination_file"
}

install_module_layout() {
  local module_name="$1"
  local module_dir="$REPO_ROOT/$module_name"
  local manifest_file="$module_dir/module.env"
  local config_dirs
  local example_files
  local path_entries=()
  local relative_path

  install_directory "$CONFIG_ROOT/$module_name"

  config_dirs="$(read_manifest_value "$manifest_file" "REQUIRED_CONFIG_DIRS")"
  if [[ -n "$config_dirs" ]]; then
    read -r -a path_entries <<< "$config_dirs"
    for relative_path in "${path_entries[@]}"; do
      install_directory "$CONFIG_ROOT/$module_name/$relative_path"
    done
  fi

  [[ "$INSTALL_EXAMPLES" == "1" ]] || return

  if [[ -f "$module_dir/runtime.env.example" ]]; then
    install_example_atomic \
      "$module_dir/runtime.env.example" \
      "$CONFIG_ROOT/$module_name/runtime.env.example"
  fi

  example_files="$(read_manifest_value "$manifest_file" "EXAMPLE_CONFIG_FILES")"
  path_entries=()
  if [[ -n "$example_files" ]]; then
    read -r -a path_entries <<< "$example_files"
    for relative_path in "${path_entries[@]}"; do
      install_example_atomic \
        "$module_dir/$relative_path" \
        "$CONFIG_ROOT/$module_name/$relative_path"
    done
  fi
}

apply_install_plan() {
  local module_name

  [[ "$(uname -s)" == "Linux" ]] || fail "--apply requires Linux"
  [[ "$EUID" == "0" ]] || fail "--apply requires root privileges"

  require_command install
  require_command mktemp
  require_command mv
  require_command mkdir
  require_command rmdir
  require_command rm

  install_directory "$RUN_ROOT"
  acquire_deployment_lock "$RUN_ROOT"

  install_directory "$CONFIG_ROOT"
  for module_name in "${SELECTED_MODULES[@]}"; do
    install_module_layout "$module_name"
  done

  if [[ "$INSTALL_EXAMPLES" == "1" ]]; then
    install_example_atomic \
      "$REPO_ROOT/server.env.example" \
      "$CONFIG_ROOT/server.env.example"
    install_example_atomic \
      "$REPO_ROOT/modules.env.example" \
      "$CONFIG_ROOT/modules.env.example"
  fi

  ok "host layout prepared without creating active runtime configuration"
}

parse_arguments() {
  local config_root_set=0

  while (($# > 0)); do
    case "$1" in
      --config-root)
        (($# >= 2)) || fail "Missing value for --config-root"
        [[ "$config_root_set" == "0" ]] || \
          fail "--config-root may be specified only once"
        [[ -n "$2" ]] || fail "Missing value for --config-root"
        CONFIG_ROOT="$2"
        config_root_set=1
        shift 2
        ;;
      --config-root=*)
        [[ "$config_root_set" == "0" ]] || \
          fail "--config-root may be specified only once"
        CONFIG_ROOT="${1#*=}"
        [[ -n "$CONFIG_ROOT" ]] || fail "Missing value for --config-root"
        config_root_set=1
        shift
        ;;
      --module)
        (($# >= 2)) || fail "Missing value for --module"
        [[ -n "$2" ]] || fail "Missing value for --module"
        REQUESTED_MODULES+=("$2")
        shift 2
        ;;
      --module=*)
        REQUESTED_MODULES+=("${1#*=}")
        [[ -n "${REQUESTED_MODULES[${#REQUESTED_MODULES[@]}-1]}" ]] || \
          fail "Missing value for --module"
        shift
        ;;
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
      --install-examples)
        [[ "$INSTALL_EXAMPLES" == "0" ]] || \
          fail "--install-examples may be specified only once"
        INSTALL_EXAMPLES=1
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

  [[ -n "$OPERATION" ]] || fail "Specify exactly one of --check or --apply"
  validate_config_root_path "$CONFIG_ROOT"

  if [[ "$INSTALL_EXAMPLES" == "1" ]]; then
    [[ -f "$REPO_ROOT/server.env.example" ]] || \
      fail "Root example not found: $REPO_ROOT/server.env.example"
    [[ -f "$REPO_ROOT/modules.env.example" ]] || \
      fail "Root example not found: $REPO_ROOT/modules.env.example"
  fi

  select_modules
  validate_selected_modules
  show_install_plan

  if [[ "$OPERATION" == "check" ]]; then
    if [[ "$SELECTED_HAS_HOST" == "1" && "$(uname -s)" != "Linux" ]]; then
      warn "Host apply requires Linux; check mode made no changes"
    fi
    ok "install preflight complete; no host changes made"
    return
  fi

  apply_install_plan
}

main "$@"
